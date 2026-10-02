# rails-logparse
Utility tool to parse & ingest Rails logs into a database format, and a web viewer tool to allow you to view and filter
request logs.

## AI Disclosure ([RAID](https://responsibleaidisclosure.com/))
![Image: This software was created using AI tools.](https://github.com/waltzaround/RAID/blob/main/assets/AI.png)

This software was created using "AI" (LLM) tools. No hard feelings if that puts you off.

## Install
Clone the repo and `bundle install`.

## Usage
To ingest a rails log:

```
ruby logparse.rb ~/path/to/file.log
```

Any lines that didn't match the usual Rails log format will be dumped out to `./unmatched_lines.txt`.

Once the log has been ingested, start the server to view and filter logs. You can specify optional BIND and PORT
environment variables.

```
ruby server.rb
```

If you want to do more complex querying yourself, the database is stored at `./logs.sqlite3`. The schema can be found
in the `create_schema` method in `logparse.rb`, or using your preferred database tooling.
