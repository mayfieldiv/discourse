# frozen_string_literal: true

require "sqlite3"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::YafSqlite < ImportScripts::Base
  BATCH_SIZE = 100

  def initialize(db_file_path)
    super()
    @db = SQLite3::Database.new(db_file_path, results_as_hash: true)
  end

  def execute
    puts "", "Importing from SQLite file..."
    import_categories
    import_users
  end

  def import_categories
    puts "", "creating categories"
    rows = @db.execute(<<-SQL)
        SELECT *
        FROM yaf_Forum
        ORDER BY SortOrder, Name
    SQL

    created, skipped = create_categories(rows) do |row|
      {
        id: row['ForumID'],
        name: row['Name'],
        description: row['Description'],
        position: row['SortOrder'],
        post_create_action: proc do |category|
          url = "yaf_topics#{category.custom_fields["import_id"]}"
          puts "category permalink: #{url} => #{category.id}"
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

      next if all_records_exist?(:users, rows.map { |row| row['UserID'] })

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
end

unless ARGV[0] && File.exist?(ARGV[0])
  puts "", "Usage:", "", "bundle exec ruby script/import_scripts/yaf_sqlite.rb FILENAME", ""
  exit 1
end

ImportScripts::YafSqlite.new(ARGV[0]).perform
