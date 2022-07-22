# frozen_string_literal: true

require "sqlite3"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::YafSqlite < ImportScripts::Base
  BATCH_SIZE = 1000

  def initialize(db_file_path)
    super()
    @db = SQLite3::Database.new(db_file_path, results_as_hash: true)
    @bbcode_to_md = false
  end

  def execute
    puts "", "Importing from SQLite file..."
    import_categories
    import_users
    import_topics
    import_posts
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
          username: row['Name'],
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

      # if all_records_exist?(:posts, rows.map { |row| row['MessageID'] })
      #   skipped += rows.count
      #   next
      # end

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

      # if all_records_exist?(:posts, rows.map { |row| row['MessageID'] })
      #   skipped += rows.count
      #   next
      # end

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

  def process_raw_text(raw)
    return "" if raw.blank?
    text = raw.dup

    text.gsub!(/\[(quote|quote=.*?)\]/, "\n[\\1]\n") # ensure newline before/after open quote
    text.gsub!(/(\[\/quote\])/, "\n\\1\n") # ensure newline before/after end quote
    text.gsub!(/\[quote=([^\]]+?);\d*\]/, '[quote=\1]') # TODO convert to post/topic reference instead of stripping

    text.gsub!(/\[(b|i|u|s)\]\n+/, '[\1]') # strip newlines after opening single-line tags
    text.gsub!(/\n+\[\/(b|i|u|s)\]/, '[/\1]') # strip newlines before closing single-line tags

    text.gsub!(/\[img\](.+?)\[\/img\]/, '[img=\1] [/img]')
    text.gsub!('[img][/img]', '') # remove empty img tags
    text.gsub!('][/img]', '] [/img]') # ensure non-empty alt-text/title

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
