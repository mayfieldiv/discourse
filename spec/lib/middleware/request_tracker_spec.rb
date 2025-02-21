# frozen_string_literal: true

RSpec.describe Middleware::RequestTracker do
  def env(opts = {})
    create_request_env.merge(
      "HTTP_HOST" => "http://test.com",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36",
      "REQUEST_URI" => "/path?bla=1",
      "REQUEST_METHOD" => "GET",
      "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8",
      "rack.input" => StringIO.new
    ).merge(opts)
  end

  before do
    ApplicationRequest.enable
    CachedCounting.reset
    CachedCounting.enable
  end

  after do
    ApplicationRequest.disable
    CachedCounting.disable
  end

  context "full request" do
    it "can handle rogue user agents" do
      agent = (+"Evil Googlebot String \xc3\x28").force_encoding("Windows-1252")

      middleware = Middleware::RequestTracker.new(->(env) { ["200", { "Content-Type" => "text/html" }, [""]] })
      middleware.call(env("HTTP_USER_AGENT" => agent))

      CachedCounting.flush

      expect(WebCrawlerRequest.where(user_agent: agent.encode('utf-8')).count).to eq(1)
    end
  end

  context "log_request" do
    before do
      freeze_time
      ApplicationRequest.clear_cache!
    end

    def log_tracked_view(val)
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_DISCOURSE_TRACK_VIEW" => val
      ), ["200", { "Content-Type" => 'text/html' }], 0.2)

      Middleware::RequestTracker.log_request(data)
    end

    it "can exclude/include based on custom header" do
      log_tracked_view("true")
      log_tracked_view("1")
      log_tracked_view("false")
      log_tracked_view("0")

      CachedCounting.flush

      expect(ApplicationRequest.page_view_anon.first.count).to eq(2)
    end

    it "can log requests correctly" do
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "AdsBot-Google (+http://www.google.com/adsbot.html)"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      data = Middleware::RequestTracker.get_data(env(
        "HTTP_DISCOURSE_TRACK_VIEW" => "1"
      ), ["200", {}], 0.1)

      Middleware::RequestTracker.log_request(data)

      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 8_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Version/8.0 Mobile/12B410 Safari/600.1.4"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      # /srv/status is never a tracked view because content-type is text/plain
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "kube-probe/1.18",
        "REQUEST_URI" => "/srv/status?shutdown_ok=1",
      ), ["200", { "Content-Type" => 'text/plain' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      CachedCounting.flush

      expect(ApplicationRequest.http_total.first.count).to eq(4)
      expect(ApplicationRequest.http_2xx.first.count).to eq(4)

      expect(ApplicationRequest.page_view_anon.first.count).to eq(2)
      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
      expect(ApplicationRequest.page_view_anon_mobile.first.count).to eq(1)

      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
    end

    it "can log Discourse user agent requests correctly" do
      # log discourse api agents as crawlers for page view stats...
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "DiscourseAPI Ruby Gem 0.19.0"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      CachedCounting.flush
      CachedCounting.reset

      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)

      # ...but count our mobile app user agents as regular visits
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "Mozilla/5.0 AppleWebKit/605.1.15 Mobile/15E148 DiscourseHub)"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      CachedCounting.flush

      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
      expect(ApplicationRequest.page_view_anon.first.count).to eq(1)
    end

    context "ignore anonymous page views" do
      let(:anon_data) do
        Middleware::RequestTracker.get_data(env(
          "HTTP_USER_AGENT" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.72 Safari/537.36"
        ), ["200", { "Content-Type" => 'text/html' }], 0.1)
      end

      let(:logged_in_data) do
        user = Fabricate(:user, active: true)
        token = UserAuthToken.generate!(user_id: user.id)
        cookie = create_auth_cookie(
          token: token.unhashed_auth_token,
          user_id: user.id,
          trust_level: user.trust_level,
          issued_at: 5.minutes.ago
        )
        Middleware::RequestTracker.get_data(env(
          "HTTP_USER_AGENT" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.72 Safari/537.36",
          "HTTP_COOKIE" => "_t=#{cookie};"
        ), ["200", { "Content-Type" => 'text/html' }], 0.1)
      end

      it "does not ignore anonymous requests for public sites" do
        SiteSetting.login_required = false

        Middleware::RequestTracker.log_request(anon_data)
        Middleware::RequestTracker.log_request(logged_in_data)

        CachedCounting.flush

        expect(ApplicationRequest.http_total.first.count).to eq(2)
        expect(ApplicationRequest.http_2xx.first.count).to eq(2)

        expect(ApplicationRequest.page_view_logged_in.first.count).to eq(1)
        expect(ApplicationRequest.page_view_anon.first.count).to eq(1)
      end

      it "ignores anonymous requests for private sites" do
        SiteSetting.login_required = true

        Middleware::RequestTracker.log_request(anon_data)
        Middleware::RequestTracker.log_request(logged_in_data)

        CachedCounting.flush

        expect(ApplicationRequest.http_total.first.count).to eq(2)
        expect(ApplicationRequest.http_2xx.first.count).to eq(2)

        expect(ApplicationRequest.page_view_logged_in.first.count).to eq(1)
        expect(ApplicationRequest.page_view_anon.first).to eq(nil)
      end
    end
  end

  context "rate limiting" do
    before do
      RateLimiter.enable
      RateLimiter.clear_all_global!
      RateLimiter.clear_all!

      @orig_logger = Rails.logger
      Rails.logger = @fake_logger = FakeLogger.new

      # rate limiter tests depend on checks for retry-after
      # they can be sensitive to clock skew during test runs
      freeze_time DateTime.parse('2021-01-01 01:00')
    end

    after do
      Rails.logger = @orig_logger
    end

    let :middleware do
      app = lambda do |env|
        [200, {}, ["OK"]]
      end

      Middleware::RequestTracker.new(app)
    end

    it "does nothing if configured to do nothing" do
      global_setting :max_reqs_per_ip_mode, "none"
      global_setting :max_reqs_per_ip_per_10_seconds, 1

      status, _ = middleware.call(env)
      status, _ = middleware.call(env)

      expect(status).to eq(200)
    end

    it "blocks private IPs if not skipped" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'
      global_setting :max_reqs_rate_limit_on_private, true

      addresses = %w[127.1.2.3 127.0.0.2 192.168.1.2 10.0.1.2 172.16.9.8 172.19.1.2 172.20.9.8 172.29.1.2 172.30.9.8 172.31.1.2]
      warn_count = 1
      addresses.each do |addr|
        env1 = env("REMOTE_ADDR" => addr)

        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)

        expect(@fake_logger.warnings.count { |w| w.include?("Global IP rate limit exceeded") }).to eq(warn_count)
        expect(status).to eq(429)
        warn_count += 1
      end
    end

    it "blocks if the ip isn't static skipped" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'block'

      env1 = env("REMOTE_ADDR" => "1.1.1.1")
      status, _ = middleware.call(env1)
      status, _ = middleware.call(env1)
      expect(status).to eq(429)
    end

    it "doesn't block if rate limiter is enabled but IP is on the static exception list" do
      stub_const(Middleware::RequestTracker, "STATIC_IP_SKIPPER", "177.33.14.73 191.209.88.192/30"&.split&.map { |ip| IPAddr.new(ip) }) do
        global_setting :max_reqs_per_ip_per_10_seconds, 1
        global_setting :max_reqs_per_ip_mode, 'block'

        env1 = env("REMOTE_ADDR" => "177.33.14.73")
        env2 = env("REMOTE_ADDR" => "191.209.88.194")

        status, _ = middleware.call(env1)
        expect(status).to eq(200)

        status, _ = middleware.call(env1)
        expect(status).to eq(200)

        status, _ = middleware.call(env2)
        expect(status).to eq(200)

        status, _ = middleware.call(env2)
        expect(status).to eq(200)
      end
    end

    describe "register_ip_skipper" do
      before do
        Middleware::RequestTracker.register_ip_skipper do |ip|
          ip == "1.1.1.2"
        end
        global_setting :max_reqs_per_ip_per_10_seconds, 1
        global_setting :max_reqs_per_ip_mode, 'block'
      end

      after do
        Middleware::RequestTracker.unregister_ip_skipper
      end

      it "won't block if the ip is skipped" do
        env1 = env("REMOTE_ADDR" => "1.1.1.2")
        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)
        expect(status).to eq(200)
      end

      it "blocks if the ip isn't skipped" do
        env1 = env("REMOTE_ADDR" => "1.1.1.1")
        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)
        expect(status).to eq(429)
      end
    end

    it "does nothing for private IPs if skipped" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'
      global_setting :max_reqs_rate_limit_on_private, false

      addresses = %w[127.1.2.3 127.0.3.1 192.168.1.2 10.0.1.2 172.16.9.8 172.19.1.2 172.20.9.8 172.29.1.2 172.30.9.8 172.31.1.2]
      addresses.each do |addr|
        env1 = env("REMOTE_ADDR" => addr)

        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)

        expect(@fake_logger.warnings.count { |w| w.include?("Global IP rate limit exceeded") }).to eq(0)
        expect(status).to eq(200)
      end
    end

    it "does warn if rate limiter is enabled via warn+block" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'

      status, _ = middleware.call(env)
      status, headers = middleware.call(env)

      expect(@fake_logger.warnings.count { |w| w.include?("Global IP rate limit exceeded") }).to eq(1)
      expect(status).to eq(429)
      expect(headers["Retry-After"]).to eq("10")
    end

    it "does warn if rate limiter is enabled" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn'

      status, _ = middleware.call(env)
      status, _ = middleware.call(env)

      expect(@fake_logger.warnings.count { |w| w.include?("Global IP rate limit exceeded") }).to eq(1)
      expect(status).to eq(200)
    end

    it "allows assets for more requests" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'block'
      global_setting :max_asset_reqs_per_ip_per_10_seconds, 3

      env1 = env("REMOTE_ADDR" => "1.1.1.1", "DISCOURSE_IS_ASSET_PATH" => 1)

      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, headers = middleware.call(env1)
      expect(status).to eq(429)
      expect(headers["Retry-After"]).to eq("10")

      env2 = env("REMOTE_ADDR" => "1.1.1.1")

      status, headers = middleware.call(env2)
      expect(status).to eq(429)
      expect(headers["Retry-After"]).to eq("10")
    end

    it "does block if rate limiter is enabled" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'block'

      env1 = env("REMOTE_ADDR" => "1.1.1.1")
      env2 = env("REMOTE_ADDR" => "1.1.1.2")

      status, _ = middleware.call(env1)
      expect(status).to eq(200)

      status, headers = middleware.call(env1)
      expect(status).to eq(429)
      expect(headers["Retry-After"]).to eq("10")

      status, _ = middleware.call(env2)
      expect(status).to eq(200)
    end

    describe "diagnostic information" do
      it "is included when the requests-per-10-seconds limit is reached" do
        global_setting :max_reqs_per_ip_per_10_seconds, 1
        called = 0
        app = lambda do |_|
          called += 1
          [200, {}, ["OK"]]
        end
        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, = middleware.call(env)
        expect(status).to eq(200)
        expect(called).to eq(1)

        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, headers, response = middleware.call(env)
        expect(status).to eq(429)
        expect(called).to eq(1)
        expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("ip_10_secs_limit")
        expect(response.first).to include("Error code: ip_10_secs_limit.")
      end

      it "is included when the requests-per-minute limit is reached" do
        global_setting :max_reqs_per_ip_per_minute, 1
        called = 0
        app = lambda do |_|
          called += 1
          [200, {}, ["OK"]]
        end
        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, = middleware.call(env)
        expect(status).to eq(200)
        expect(called).to eq(1)

        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, headers, response = middleware.call(env)
        expect(status).to eq(429)
        expect(called).to eq(1)
        expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("ip_60_secs_limit")
        expect(response.first).to include("Error code: ip_60_secs_limit.")
      end

      it "is included when the assets-requests-per-10-seconds limit is reached" do
        global_setting :max_asset_reqs_per_ip_per_10_seconds, 1
        called = 0
        app = lambda do |env|
          called += 1
          env["DISCOURSE_IS_ASSET_PATH"] = true
          [200, {}, ["OK"]]
        end
        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, = middleware.call(env)
        expect(status).to eq(200)
        expect(called).to eq(1)

        env = env("REMOTE_ADDR" => "1.1.1.1")
        middleware = Middleware::RequestTracker.new(app)
        status, headers, response = middleware.call(env)
        expect(status).to eq(429)
        expect(called).to eq(1)
        expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("ip_assets_10_secs_limit")
        expect(response.first).to include("Error code: ip_assets_10_secs_limit.")
      end
    end

    it "users with high enough trust level are not rate limited per ip" do
      global_setting :max_reqs_per_ip_per_minute, 1
      global_setting :skip_per_ip_rate_limit_trust_level, 3

      envs = 3.times.map do |n|
        user = Fabricate(:user, trust_level: 3)
        token = UserAuthToken.generate!(user_id: user.id)
        cookie = create_auth_cookie(
          token: token.unhashed_auth_token,
          user_id: user.id,
          trust_level: user.trust_level,
          issued_at: 5.minutes.ago
        )
        env("HTTP_COOKIE" => "_t=#{cookie}", "REMOTE_ADDR" => "1.1.1.1")
      end

      called = 0
      app = lambda do |env|
        called += 1
        [200, {}, ["OK"]]
      end
      envs.each do |env|
        middleware = Middleware::RequestTracker.new(app)
        status, = middleware.call(env)
        expect(status).to eq(200)
      end
      expect(called).to eq(3)

      envs.each do |env|
        middleware = Middleware::RequestTracker.new(app)
        status, headers, response = middleware.call(env)
        expect(status).to eq(429)
        expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("id_60_secs_limit")
        expect(response.first).to include("Error code: id_60_secs_limit.")
      end
      expect(called).to eq(3)
    end

    it "falls back to IP rate limiting if the cookie is too old" do
      unfreeze_time
      global_setting :max_reqs_per_ip_per_minute, 1
      global_setting :skip_per_ip_rate_limit_trust_level, 3
      user = Fabricate(:user, trust_level: 3)
      token = UserAuthToken.generate!(user_id: user.id)
      cookie = create_auth_cookie(
        token: token.unhashed_auth_token,
        user_id: user.id,
        trust_level: user.trust_level,
        issued_at: 5.minutes.ago
      )
      env = env("HTTP_COOKIE" => "_t=#{cookie}", "REMOTE_ADDR" => "1.1.1.1")

      called = 0
      app = lambda do |_|
        called += 1
        [200, {}, ["OK"]]
      end
      freeze_time(12.minutes.from_now) do
        middleware = Middleware::RequestTracker.new(app)
        status, = middleware.call(env)
        expect(status).to eq(200)

        middleware = Middleware::RequestTracker.new(app)
        status, headers, response = middleware.call(env)
        expect(status).to eq(429)
        expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("ip_60_secs_limit")
        expect(response.first).to include("Error code: ip_60_secs_limit.")
      end
    end

    it "falls back to IP rate limiting if the cookie is tampered with" do
      unfreeze_time
      global_setting :max_reqs_per_ip_per_minute, 1
      global_setting :skip_per_ip_rate_limit_trust_level, 3
      user = Fabricate(:user, trust_level: 3)
      token = UserAuthToken.generate!(user_id: user.id)
      cookie = create_auth_cookie(
        token: token.unhashed_auth_token,
        user_id: user.id,
        trust_level: user.trust_level,
        issued_at: Time.zone.now
      )
      cookie = swap_2_different_characters(cookie)
      env = env("HTTP_COOKIE" => "_t=#{cookie}", "REMOTE_ADDR" => "1.1.1.1")

      called = 0
      app = lambda do |_|
        called += 1
        [200, {}, ["OK"]]
      end

      middleware = Middleware::RequestTracker.new(app)
      status, = middleware.call(env)
      expect(status).to eq(200)

      middleware = Middleware::RequestTracker.new(app)
      status, headers, response = middleware.call(env)
      expect(status).to eq(429)
      expect(headers["Discourse-Rate-Limit-Error-Code"]).to eq("ip_60_secs_limit")
      expect(response.first).to include("Error code: ip_60_secs_limit.")
    end
  end

  context "callbacks" do
    def app(result, sql_calls: 0, redis_calls: 0)
      lambda do |env|
        sql_calls.times do
          User.where(id: -100).pluck(:id)
        end
        redis_calls.times do
          Discourse.redis.get("x")
        end
        result
      end
    end

    let(:logger) do
      ->(env, data) do
        @env = env
        @data = data
      end
    end

    before do
      Middleware::RequestTracker.register_detailed_request_logger(logger)
    end

    after do
      Middleware::RequestTracker.unregister_detailed_request_logger(logger)
    end

    it "can report data from anon cache" do
      cache = Middleware::AnonymousCache.new(app([200, {}, ["i am a thing"]]))
      tracker = Middleware::RequestTracker.new(cache)

      uri = "/path?#{SecureRandom.hex}"

      request_params = {
        "a" => "b",
        "action" => "bob",
        "controller" => "jane"
      }

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60, "action_dispatch.request.parameters" => request_params))
      expect(@data[:cache]).to eq("skip")

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60, "action_dispatch.request.parameters" => request_params))
      expect(@data[:cache]).to eq("store")

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60))
      expect(@data[:cache]).to eq("true")

      # not allowlisted
      request_params.delete("a")

      expect(@env["action_dispatch.request.parameters"]).to eq(request_params)
    end

    it "can correctly log detailed data" do
      global_setting :enable_performance_http_headers, true

      # ensure pg is warmed up with the select 1 query
      User.where(id: -100).pluck(:id)

      freeze_time
      start = Time.now.to_f

      freeze_time 1.minute.from_now

      tracker = Middleware::RequestTracker.new(app([200, {}, []], sql_calls: 2, redis_calls: 2))
      _, headers, _ = tracker.call(env("HTTP_X_REQUEST_START" => "t=#{start}"))

      expect(@data[:queue_seconds]).to eq(60)

      timing = @data[:timing]
      expect(timing[:total_duration]).to be > 0

      expect(timing[:sql][:duration]).to be > 0
      expect(timing[:sql][:calls]).to eq 2

      expect(timing[:redis][:duration]).to be > 0
      expect(timing[:redis][:calls]).to eq 2

      expect(headers["X-Queue-Time"]).to eq("60.000000")

      expect(headers["X-Redis-Calls"]).to eq("2")
      expect(headers["X-Redis-Time"].to_f).to be > 0

      expect(headers["X-Sql-Calls"]).to eq("2")
      expect(headers["X-Sql-Time"].to_f).to be > 0

      expect(headers["X-Runtime"].to_f).to be > 0
    end
  end
end
