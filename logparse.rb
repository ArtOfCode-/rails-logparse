#!/usr/bin/env ruby

require 'sqlite3'
require 'time'

LOG_LINE = /^(?:([A-Z]), \[([\d\-T:\.]+) #(\d+)\] +([A-Z]+) -- : )?\[([a-z\-]+)\] \[([a-f0-9\-]+)\] +(.*)$/
COMPLETION_LINE = /\bCompleted .*? in ([\d.]+)ms \(Views: ([\d.]+)ms \| ActiveRecord: ([\d.]+)ms\b/
STARTED_LINE = /\AStarted (\S+) "([^"]*)"/
PROGRESS_BAR_WIDTH = 40

def print_progress(processed, total)
  fraction = total.zero? ? 1.0 : processed.to_f / total
  filled = (fraction * PROGRESS_BAR_WIDTH).round
  bar = "=" * filled + " " * (PROGRESS_BAR_WIDTH - filled)
  percentage = (fraction * 100).round
  print "\rProgress: [#{bar}] #{percentage}% (#{processed}/#{total})"
  $stdout.flush
end

def create_schema(database)
  database.execute_batch(<<~SQL)
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      log_level TEXT NOT NULL,
      created DATETIME NOT NULL,
      pid INTEGER NOT NULL,
      full_log_level TEXT NOT NULL,
      subdomain TEXT NOT NULL,
      request_uuid TEXT NOT NULL,
      log_message TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS requests (
      request_uuid TEXT PRIMARY KEY,
      subdomain TEXT,
      method TEXT,
      path TEXT,
      started_at DATETIME NOT NULL,
      total INTEGER,
      views INTEGER,
      db INTEGER
    );

    CREATE INDEX entries_request_uuid ON entries (request_uuid);
  SQL

  request_columns = database.execute("PRAGMA table_info(requests)").map { |column| column[1] }
  database.execute("ALTER TABLE requests ADD COLUMN method TEXT") unless request_columns.include?("method")
  database.execute("ALTER TABLE requests ADD COLUMN path TEXT") unless request_columns.include?("path")
end

def import_log(log_path, database)
  total_lines = File.foreach(log_path).count
  processed_lines = 0
  unmatched_lines = 0
  progress_interval = [total_lines / 100, 1].max

  insert_entry = database.prepare(<<~SQL)
    INSERT INTO entries (
      log_level, created, pid, full_log_level, subdomain, request_uuid, log_message
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  SQL
  insert_request = database.prepare(<<~SQL)
    INSERT INTO requests (request_uuid, subdomain, method, path, started_at, total, views, db)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  SQL
  update_request = database.prepare(<<~SQL)
    UPDATE requests
    SET subdomain = ?,
      method = COALESCE(method, ?),
        path = COALESCE(path, ?),
        started_at = ?,
        total = COALESCE(?, total),
        views = COALESCE(?, views),
        db = COALESCE(?, db)
    WHERE request_uuid = ?
  SQL

  File.open("unmatched_lines.txt", "w") do |unmatched_file|
    database.transaction do
      File.foreach(log_path) do |line|
        processed_lines += 1
        match = LOG_LINE.match(line.chomp)
        unless match
          unmatched_file.write(line)
          unmatched_lines += 1
          print_progress(processed_lines, total_lines) if processed_lines % progress_interval == 0 || processed_lines == total_lines
          next
        end

        log_level, created, pid, full_log_level, subdomain, request_uuid, message = match.captures
        # Prefixless lines lack level, timestamp, and PID; keep legacy NOT NULL columns populated.
        log_level ||= ''
        created ||= Time.now.utc.iso8601(3)
        pid = (pid || 0).to_i
        full_log_level ||= ''
        insert_entry.execute(log_level, created, pid, full_log_level, subdomain, request_uuid, message)
        request_method, path = STARTED_LINE.match(message)&.captures

        existing_request = database.get_first_row(
          "SELECT started_at, path, method FROM requests WHERE request_uuid = ?", request_uuid
        )
        if existing_request
          started_at = [existing_request[0], created].min
          path ||= existing_request[1]
          request_method ||= existing_request[2]
        else
          started_at = created
        end

        completion = COMPLETION_LINE.match(message)
        metrics = completion ? completion.captures.map(&:to_i) : [nil, nil, nil]

        if existing_request
          update_request.execute(subdomain, request_method, path, started_at, *metrics, request_uuid)
        else
          insert_request.execute(request_uuid, subdomain, request_method, path, started_at, *metrics)
        end

        print_progress(processed_lines, total_lines) if processed_lines % progress_interval == 0 || processed_lines == total_lines
      end
    end
  end

  print_progress(processed_lines, total_lines) if total_lines.zero?
  puts
  puts "Import complete: #{processed_lines} lines processed; #{unmatched_lines} did not match the log format."
  puts "Unmatched lines written to unmatched_lines.txt."
ensure
  [insert_entry, insert_request, update_request].compact.each(&:close)
end

if ARGV.empty?
  warn "Usage: ruby logparse.rb PATH_TO_RAILS_LOG"
  exit 1
end

log_path = ARGV[0]
unless File.file?(log_path)
  warn "Log file not found: #{log_path}"
  exit 1
end

database = SQLite3::Database.new("./logs.sqlite3")
begin
  create_schema(database)
  import_log(log_path, database)
ensure
  database.close
end

