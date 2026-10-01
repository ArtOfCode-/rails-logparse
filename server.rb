require 'sinatra/base'
require 'sqlite3'
require 'date'
require 'time'
require 'uri'

class LogExplorer < Sinatra::Base
	set :root, __dir__
	set :views, File.join(__dir__, 'views')
	set :public_folder, File.join(__dir__, 'public')
	set :bind, ENV.fetch('BIND', '0.0.0.0')
	set :port, ENV.fetch('PORT', '4567').to_i

	DATABASE_PATH = ENV.fetch('LOGS_DATABASE_PATH', File.join(__dir__, 'logs.sqlite3'))
	TIMEFRAMES = {
		'24h' => { label: '24 hours', modifier: '-24 hours', seconds: 24 * 60 * 60, format: '%Y-%m-%d %H' },
		'12h' => { label: '12 hours', modifier: '-12 hours', seconds: 12 * 60 * 60, format: '%Y-%m-%d %H' },
		'6h' => { label: '6 hours', modifier: '-6 hours', seconds: 6 * 60 * 60, format: '%Y-%m-%d %H' },
    '3h' => { label: '3 hours', modifier: '-3 hours', seconds: 3 * 60 * 60, format: '%Y-%m-%d %H' },
    '1h' => { label: '1 hour', modifier: '-1 hour', seconds: 1 * 60 * 60, format: '%Y-%m-%d %H' }
	}.freeze

	before do
		@database = SQLite3::Database.new(DATABASE_PATH)
		@database.results_as_hash = true
	end

	after do
		@database&.close
	end

	helpers do
		def h(value)
			Rack::Utils.escape_html(value.to_s)
		end

		def formatted_time(value)
			return '—' if value.nil? || value.empty?

			Time.parse(value).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
		rescue ArgumentError
			value
		end

		def duration(value)
			value.nil? ? '—' : "#{value} ms"
		end

		def request_rows(limit:, offset: 0)
			@database.execute(<<~SQL, [limit, offset])
				SELECT requests.*
				FROM requests
				ORDER BY started_at DESC, request_uuid DESC
				LIMIT ? OFFSET ?
			SQL
		end

		def requests_page_url(page)
			query = @filters.merge(page: page).reject { |_key, value| value.nil? || value.to_s.empty? }
			"/requests?#{URI.encode_www_form(query)}"
		end
	end

	get '/' do
		@timeframe_key = TIMEFRAMES.key?(params['range']) ? params['range'] : '24h'
		@timeframe = TIMEFRAMES.fetch(@timeframe_key)
		@summary = @database.get_first_row(<<~SQL, @timeframe[:modifier])
			SELECT COUNT(*) AS count, AVG(total) AS average_total,
						 SUM(views) AS views, SUM(db) AS database
			FROM requests
			WHERE datetime(started_at) >= datetime('now', ?) AND datetime(started_at) <= datetime('now')
		SQL

		grouped = @database.execute(
			"SELECT strftime(?, started_at) AS bucket, COUNT(*) AS count " \
			"FROM requests WHERE datetime(started_at) >= datetime('now', ?) " \
				"AND datetime(started_at) <= datetime('now') GROUP BY bucket",
				[@timeframe[:format], @timeframe[:modifier]]
		)
		counts = grouped.to_h { |row| [row['bucket'], row['count']] }
		now = Time.now.utc
		if @timeframe_key == '24h'
			current_hour = Time.utc(now.year, now.month, now.day, now.hour)
			@chart = (23.downto(0)).map do |hours_ago|
				bucket_time = current_hour - hours_ago * 60 * 60
				{ label: bucket_time.strftime('%H:%M'), key: bucket_time.strftime('%Y-%m-%d %H'), title: bucket_time.strftime('%b %-d, %H:00 UTC') }
			end
		else
			days = @timeframe_key == '7d' ? 7 : 30
			today = Time.now.utc.to_date
			@chart = (days - 1).downto(0).map do |days_ago|
				bucket_date = today - days_ago
				{ label: bucket_date.strftime(days == 7 ? '%a' : '%d'), key: bucket_date.strftime('%Y-%m-%d'), title: bucket_date.strftime('%b %-d') }
			end
		end
		@chart.each { |bucket| bucket[:count] = counts.fetch(bucket[:key], 0) }
		@chart_max = [@chart.map { |bucket| bucket[:count] }.max || 0, 1].max
		@requests = request_rows(limit: 50)
		erb :index
	end

	get '/requests' do
		@filters = {
			method: params['method'].to_s.strip,
			path: params['path'].to_s.strip,
			subdomain: params['subdomain'].to_s.strip,
			from: params['from'].to_s.strip,
			to: params['to'].to_s.strip
		}
		@methods = @database.execute(
			"SELECT DISTINCT method FROM requests WHERE method IS NOT NULL AND method != '' ORDER BY method"
		).map { |row| row['method'] }

		conditions = []
		bindings = []
		unless @filters[:method].empty?
			conditions << 'method = ?'
			bindings << @filters[:method]
		end
		unless @filters[:path].empty?
			conditions << "instr(lower(COALESCE(path, '')), lower(?)) > 0"
			bindings << @filters[:path]
		end
		unless @filters[:subdomain].empty?
			conditions << "instr(lower(COALESCE(subdomain, '')), lower(?)) > 0"
			bindings << @filters[:subdomain]
		end
		{ from: '>=', to: '<=' }.each do |key, operator|
			value = @filters[key]
			next if value.empty?

			begin
				parsed_time = Time.parse("#{value} UTC").utc.strftime('%Y-%m-%d %H:%M:%S')
				conditions << "datetime(started_at) #{operator} datetime(?)"
				bindings << parsed_time
			rescue ArgumentError
				@filter_error = "Invalid #{key == :from ? 'start' : 'end'} time; use a valid date and time."
			end
		end
		where_clause = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"
		@page = [[params.fetch('page', '1').to_i, 1].max, 1_000_000].min
		@per_page = 50
		@total_requests = @database.get_first_value(
			"SELECT COUNT(*) FROM requests #{where_clause}", bindings
		).to_i
		@total_pages = [(@total_requests.to_f / @per_page).ceil, 1].max
		@page = [@page, @total_pages].min
		@requests = @database.execute(<<~SQL, bindings + [@per_page, (@page - 1) * @per_page])
			SELECT requests.*
			FROM requests
			#{where_clause}
			ORDER BY started_at DESC, request_uuid DESC
			LIMIT ? OFFSET ?
		SQL
		erb :requests
	end

	get '/requests/:uuid/logs' do
		content_type 'text/html'
		entries = @database.execute(
			'SELECT log_level, created, pid, full_log_level, subdomain, log_message ' \
			'FROM entries WHERE request_uuid = ? ORDER BY created ASC, id ASC',
			[params['uuid']]
		)
		halt 404, 'Request not found' if entries.empty?

		erb :request_logs, layout: false, locals: { entries: entries }
	end

	not_found do
		content_type 'text/plain'
		'Not found'
	end

	run! if $PROGRAM_NAME == __FILE__
end
