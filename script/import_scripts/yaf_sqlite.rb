# frozen_string_literal: true

require "sqlite3"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::YafSqlite < ImportScripts::Base
  BATCH_SIZE = 1000

  CATEGORY_LINK_NORMALIZATION = '/(yaf_topics\d+)_.*/\1'
  TOPIC_LINK_NORMALIZATION = '/(yaf_postst\d+)_.*/\1'
  POST_LINK_NORMALIZATION = '/(yaf_postsm\d+)_.*/\1'

  def initialize(db_file_path)
    super()
    @db = SQLite3::Database.new(db_file_path, results_as_hash: true)
    @bbcode_to_md = false
  end

  def execute
    puts "", "Importing from SQLite file..."
    add_permalink_normalizations
    import_categories
    import_users
    import_topics
    import_posts
    import_likes
  end

  def add_permalink_normalizations
    normalizations = SiteSetting.permalink_normalizations
    normalizations = normalizations.blank? ? [] : normalizations.split('|')

    def add_normalization(normalizations, normalization)
      normalizations << normalization unless normalizations.include?(normalization)
    end

    add_normalization(normalizations, CATEGORY_LINK_NORMALIZATION)
    add_normalization(normalizations, TOPIC_LINK_NORMALIZATION)
    add_normalization(normalizations, POST_LINK_NORMALIZATION)

    SiteSetting.permalink_normalizations = normalizations.join('|')
  end

  def import_categories
    puts "", "creating categories"
    rows = @db.execute("SELECT * FROM yaf_Forum ORDER BY SortOrder, Name")

    created, skipped = create_categories(rows) do |row|
      {
        id: row['ForumID'],
        name: row['Name'],
        description: row['Description'],
        position: row['SortOrder'],
        post_create_action: proc do |category|
          url = "yaf_topics#{category.custom_fields["import_id"]}"
          # puts "category permalink: #{url} => #{category.id}"
          Permalink.create(url: url, category_id: category.id) unless Permalink.find_by(url: url)
        end
      }
    end

    puts ""
    puts "Created: #{created}"
    puts "Skipped: #{skipped}"
    puts ""
  end

  def import_users
    puts "", "creating users"
    total_count = @db.get_first_value("SELECT COUNT(*) FROM yaf_User")
    last_id = '0'
    created, skipped = 0, 0

    batches(BATCH_SIZE) do |offset|
      rows = @db.execute(<<-SQL, last_id)
        SELECT yaf_User.UserID, Email, Name, RealName, Joined, LastVisit, IP, Occupation, Homepage, Location, Birthday, AvatarImageType, AvatarImage
        FROM yaf_User
        LEFT JOIN yaf_UserProfile ON yaf_User.UserID = yaf_UserProfile.UserID
        WHERE yaf_User.UserID > :last_id
        ORDER BY yaf_User.UserID
        LIMIT #{BATCH_SIZE}
      SQL

      break if rows.empty?

      last_id = rows.last['UserID']

      if all_records_exist?(:users, rows.map { |row| row['UserID'] })
        skipped += rows.count
        next
      end

      c, s = create_users(rows, total: total_count, offset: offset) do |row|
        {
          active: false,
          id: row['UserID'],
          email: row['Email'],
          name: row['RealName'],
          username: row['Name'].gsub('@', ' at '), # transform email address usernames
          created_at: row['Joined'],
          last_seen_at: row['LastVisit'],
          registration_ip_address: row['IP'],
          title: row['Occupation'],
          website: row['Homepage'],
          location: row['Location'],
          date_of_birth: row['Birthday'],
          post_create_action: proc do |user|
            # puts ""
            # puts "Created user: " + user.to_json
            # puts row
            if !row['AvatarImageType'].blank? && !row['AvatarImage'].blank?
              file_extension = "." + row['AvatarImageType'].sub('image/', '')
              avatar_path = ""
              Tempfile.open(['avatar', file_extension], encoding: 'ascii-8bit', mode: File::BINARY | File::RDWR | File::CREAT | File::EXCL) do |f|
                avatar_path = f.path
                f.write(row['AvatarImage'])
              end

              @uploader.create_avatar(user, avatar_path)
            end
          end
        }
      end
      created += c
      skipped += s
    end

    puts ""
    puts "Created: #{created}"
    puts "Skipped: #{skipped}"
    puts ""
  end

  def import_topics
    puts "", "creating topics"
    # NOTE: having an index for yaf_Message.TopicID drastically improves performance for all these post-related queries
    total_count = @db.get_first_value(<<-SQL)
      SELECT COUNT(*) FROM yaf_Topic
      WHERE (SELECT COUNT(*) FROM yaf_Message WHERE yaf_Topic.TopicID = yaf_Message.TopicID) > 0
    SQL
    last_id = '0'
    created, skipped = 0, 0

    batches(BATCH_SIZE) do |offset|
      rows = @db.execute(<<-SQL, last_id)
        SELECT ForumID, yaf_Topic.TopicID, Topic, MessageID, yaf_Message.UserID, yaf_Message.Posted, Message, yaf_Message.Edited
        FROM yaf_Topic
        JOIN yaf_Message ON yaf_Message.MessageID = (
          SELECT MessageID FROM yaf_Message
          WHERE yaf_Topic.TopicID = yaf_Message.TopicID
          ORDER BY Position ASC
          LIMIT 1
        )
        WHERE yaf_Topic.TopicID > :last_id
        ORDER BY yaf_Topic.TopicID
        LIMIT #{BATCH_SIZE}
      SQL

      break if rows.empty?

      last_id = rows.last['TopicID']

      if all_records_exist?(:posts, rows.map { |row| row['MessageID'] })
        skipped += rows.count
        next
      end

      c, s = create_posts(rows, total: total_count, offset: offset) do |row|
        {
          id: row['MessageID'],
          import_topic_id: row['TopicID'],
          title: row['Topic'].strip[0...255],
          raw: process_raw_text(row['Message']),
          category: category_id_from_imported_category_id(row['ForumID']),
          user_id: user_id_from_imported_user_id(row['UserID']) || Discourse.system_user.id,
          created_at: row['Posted'],
          updated_at: row['Edited'],
          post_create_action: proc do |post|
            url = "yaf_postst#{post.topic.custom_fields["import_topic_id"]}"
            # puts "topic permalink: #{url} => #{post.topic.id}"
            Permalink.create(url: url, topic_id: post.topic.id) unless Permalink.find_by(url: url)

            url = "yaf_postsm#{post.custom_fields["import_id"]}"
            # puts "post permalink: #{url} => #{post.id}"
            Permalink.create(url: url, post_id: post.id) unless Permalink.find_by(url: url)
          end
        }
      end
      created += c
      skipped += s
    end

    puts ""
    puts "Created: #{created}"
    puts "Skipped: #{skipped}"
    puts ""
  end

  def import_posts
    puts "", "creating posts"
    total_count = @db.get_first_value(<<-SQL)
      SELECT COUNT(*) FROM yaf_Message
      WHERE MessageID != (SELECT MessageID FROM yaf_Message m
        WHERE yaf_Message.TopicID = m.TopicID
        ORDER BY Position ASC
        LIMIT 1)
    SQL
    last_id = '0'
    created, skipped = 0, 0

    batches(BATCH_SIZE) do |offset|
      rows = @db.execute(<<-SQL, last_id)
        SELECT MessageID, UserID, Posted, Message, Edited,
         (SELECT MessageID FROM yaf_Message m
          WHERE yaf_Message.TopicID = m.TopicID
          ORDER BY Position ASC
          LIMIT 1) TopicMessageID
        FROM yaf_Message
        WHERE MessageID > :last_id AND MessageID != TopicMessageID
        ORDER BY MessageID
        LIMIT #{BATCH_SIZE}
      SQL

      break if rows.empty?

      last_id = rows.last['MessageID']

      if all_records_exist?(:posts, rows.map { |row| row['MessageID'] })
        skipped += rows.count
        next
      end

      c, s = create_posts(rows, total: total_count, offset: offset) do |row|
        topic = topic_lookup_from_imported_post_id(row['TopicMessageID'])
        if topic.nil?
          p "MISSING TOPIC #{row['TopicMessageID']}", row
          next
        end
        {
          id: row['MessageID'],
          topic_id: topic[:topic_id],
          raw: process_raw_text(row['Message']),
          user_id: user_id_from_imported_user_id(row['UserID']) || Discourse.system_user.id,
          created_at: row['Posted'],
          updated_at: row['Edited'],
          post_create_action: proc do |post|
            url = "yaf_postsm#{post.custom_fields["import_id"]}"
            # puts "post permalink: #{url} => #{post.id}"
            Permalink.create(url: url, post_id: post.id) unless Permalink.find_by(url: url)
          end
        }
      end
      created += c
      skipped += s
    end

    puts ""
    puts "Created: #{created}"
    puts "Skipped: #{skipped}"
    puts ""
  end

  def import_likes
    puts "", "creating likes"
    total_count = @db.get_first_value('SELECT COUNT(*) FROM yaf_Thanks')
    last_id = '0'
    created, skipped = 0, 0
    start_time = get_start_time("likes")

    batches(BATCH_SIZE) do |offset|
      rows = @db.execute(<<-SQL, last_id)
        SELECT ThanksID, ThanksFromUserID, MessageID, ThanksDate
        FROM yaf_Thanks
        WHERE ThanksID > :last_id
        ORDER BY ThanksID
        LIMIT #{BATCH_SIZE}
      SQL

      break if rows.empty?

      last_id = rows.last['ThanksID']
      current_count = 0

      rows.each do |row|
        post = Post.find_by(id: post_id_from_imported_post_id(row['MessageID']))
        user = User.find_by(id: user_id_from_imported_user_id(row['ThanksFromUserID']))

        if post && user
          begin
            PostActionCreator.create(user, post, :like, created_at: row['ThanksDate'])
            created += 1
          rescue => e
            puts "error acting on post #{row['MessageID']}: #{e}"
          end
        else
          puts "Skipping like from user #{row['ThanksFromUserID']} on post #{row['MessageID']}"
          skipped += 1
        end

        current_count += 1
        print_status(offset + current_count, total_count, start_time)
      end
    end

    puts ""
    puts "Created: #{created}"
    puts "Skipped: #{skipped}"
    puts ""
  end

  def process_raw_text(raw)
    return "" if raw.blank?
    text = raw.dup

    # quote
    text.gsub!(/\[(quote|quote=.*?)\]/, "\n[\\1]\n") # ensure newline before/after open quote
    text.gsub!(/(\[\/quote\])/, "\n\\1\n") # ensure newline before/after end quote
    text.gsub!(/\[quote=([^\]]+?);(\d*)\]/) { |_|
      author = Regexp.last_match[1]
      message_id = Regexp.last_match[2]
      post_id = post_id_from_imported_post_id(message_id)
      post = Post.find(post_id)
      "[quote=\"#{author}, post:#{post.post_number}, topic:#{post.topic_id}\"]"
    }

    # strip newlines before/after single-line tags
    text.gsub!(/\[(b|i|u|s)\]\n+/, '[\1]')
    text.gsub!(/\n+\[\/(b|i|u|s)\]/, '[/\1]')

    # img
    text.gsub!(/\[img\](.+?)\[\/img\]/, '[img=\1] [/img]')
    text.gsub!('[img][/img]', '') # remove empty img tags
    text.gsub!('][/img]', '] [/img]') # ensure non-empty alt-text/title

    # smileys
    text.gsub!('[angry]', ':angry:')
    text.gsub!('[biggrin]', ':grin:')
    text.gsub!('[blink]', ':hushed:')
    text.gsub!('[blush]', ':blush:')
    text.gsub!('[bored]', ':zzz:')
    text.gsub!('[confused]', ':confused:')
    text.gsub!('[cool]', ':sunglasses:')
    text.gsub!('[crying]', ':cry:')
    text.gsub!('[cursing]', ':face_with_symbols_over_mouth:')
    text.gsub!('[drool]', ':drooling_face:')
    text.gsub!('[flapper]', ':stuck_out_tongue_closed_eyes:')
    text.gsub!('[glare]', ':unamused:')
    text.gsub!('[huh]', ':confused:')
    text.gsub!('[laugh]', ':rofl:')
    text.gsub!('[lol]', ':joy:')
    text.gsub!('[love]', ':heart_eyes:')
    text.gsub!('[mad]', ':angry:')
    text.gsub!('[mellow]', ':slightly_frowning_face:')
    text.gsub!('[omg]', ':scream:')
    text.gsub!('[rolleyes]', ':roll_eyes:')
    text.gsub!('[sad]', ':frowning_face:')
    text.gsub!('[scared]', ':fearful:')
    text.gsub!('[sleep]', ':sleeping:')
    text.gsub!('[smile]', ':smile:')
    text.gsub!('[sneaky]', ':face_with_raised_eyebrow:')
    text.gsub!('[thumbdn]', ':-1:')
    text.gsub!('[thumbup]', ':+1:')
    text.gsub!('[tongue]', ':tongue:')
    text.gsub!('[razz]', ':stuck_out_tongue:')
    text.gsub!('[unsure]', ':thinking:')
    text.gsub!('[woot]', ':hushed:')
    text.gsub!('[wink]', ':wink:')
    text.gsub!('[wub]', ':heartbeat:')

    text = bbcode_to_md(text)

    text
  end

  def bbcode_to_md(text)
    begin
      additional_attributes = {
        img: {
          html_open: '![%between%](%href% "%between%")', html_close: '',
          description: 'Image',
          example: '[img=http://www.google.com/intl/en_ALL/images/logo.gif]Image title[/img].',
          only_allow: [],
          require_between: true,
          allow_tag_param: true,
          tag_param: /(.*)/,
          tag_param_tokens: [{ token: :href }],
        },
        h: {
          html_open: '## ', html_close: '',
          description: 'Header',
          example: '[h]Important Things[/h]',
        },
      }
      text.bbcode_to_md(false, additional_attributes, :disable, :quote)
    rescue => e
      puts "Problem converting \n#{text}\n using ruby-bbcode-to-md"
      text
    end
  end
end

unless ARGV[0] && File.exist?(ARGV[0])
  puts "", "Usage:", "", "bundle exec ruby script/import_scripts/yaf_sqlite.rb FILENAME", ""
  exit 1
end

ImportScripts::YafSqlite.new(ARGV[0]).perform
