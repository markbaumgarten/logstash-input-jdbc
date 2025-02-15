# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/jdbc"
require "yaml" # persistence
require "elasticsearch"
require "json"
require "rest-client"

# This plugin was created as a way to ingest data in any database
# with a JDBC interface into Logstash. You can periodically schedule ingestion
# using a cron syntax (see `schedule` setting) or run the query one time to load
# data into Logstash. Each row in the resultset becomes a single event.
# Columns in the resultset are converted into fields in the event.
#
# ==== Drivers
#
# This plugin does not come packaged with JDBC driver libraries. The desired 
# jdbc driver library must be explicitly passed in to the plugin using the
# `jdbc_driver_library` configuration option.
# 
# ==== Scheduling
#
# Input from this plugin can be scheduled to run periodically according to a specific 
# schedule. This scheduling syntax is powered by https://github.com/jmettraux/rufus-scheduler[rufus-scheduler].
# The syntax is cron-like with some extensions specific to Rufus (e.g. timezone support ).
#
# Examples:
#
# |==========================================================
# | `* 5 * 1-3 *`               | will execute every minute of 5am every day of January through March.
# | `0 * * * *`                 | will execute on the 0th minute of every hour every day.
# | `0 6 * * * America/Chicago` | will execute at 6:00am (UTC/GMT -5) every day.
# |==========================================================
#   
#
# Further documentation describing this syntax can be found https://github.com/jmettraux/rufus-scheduler#parsing-cronlines-and-time-strings[here].
#
# ==== State
#
# The plugin will persist the `sql_last_start` parameter in the form of a 
# metadata file stored in the configured `last_run_metadata_path`. Upon shutting down, 
# this file will be updated with the current value of `sql_last_start`. Next time
# the pipeline starts up, this value will be updated by reading from the file. If 
# `clean_run` is set to true, this value will be ignored and `sql_last_start` will be
# set to Jan 1, 1970, as if no query has ever been executed.
#
# ==== Dealing With Large Result-sets
#
# Many JDBC drivers use the `fetch_size` parameter to limit how many
# results are pre-fetched at a time from the cursor into the client's cache
# before retrieving more results from the result-set. This is configured in
# this plugin using the `jdbc_fetch_size` configuration option. No fetch size
# is set by default in this plugin, so the specific driver's default size will 
# be used.
#
# ==== Usage:
#
# Here is an example of setting up the plugin to fetch data from a MySQL database.
# First, we place the appropriate JDBC driver library in our current
# path (this can be placed anywhere on your filesystem). In this example, we connect to 
# the 'mydb' database using the user: 'mysql' and wish to input all rows in the 'songs'
# table that match a specific artist. The following examples demonstrates a possible 
# Logstash configuration for this. The `schedule` option in this example will 
# instruct the plugin to execute this input statement on the minute, every minute.
#
# [source,ruby]
# ----------------------------------
# input {
#   jdbc {
#     jdbc_driver_library => "mysql-connector-java-5.1.36-bin.jar"
#     jdbc_driver_class => "com.mysql.jdbc.Driver"
#     jdbc_connection_string => "jdbc:mysql://localhost:3306/mydb"
#     jdbc_user => "mysql"
#     parameters => { "favorite_artist" => "Beethoven" }
#     schedule => "* * * * *"
#     statement => "SELECT * from songs where artist = :favorite_artist"
#   }
# }
# ----------------------------------
#
# ==== Configuring SQL statement
# 
# A sql statement is required for this input. This can be passed-in via a 
# statement option in the form of a string, or read from a file (`statement_filepath`). File 
# option is typically used when the SQL statement is large or cumbersome to supply in the config.
# The file option only supports one SQL statement. The plugin will only accept one of the options.
# It cannot read a statement from a file as well as from the `statement` configuration parameter.
#
# ==== Predefined Parameters
#
# Some parameters are built-in and can be used from within your queries.
# Here is the list:
#
# |==========================================================
# |sql_last_start | The last time a statement was executed. This is set to Thursday, 1 January 1970
#  before any query is run, and updated accordingly after first query is run.
# |==========================================================
#
class LogStash::Inputs::Jdbc < LogStash::Inputs::Base
  include LogStash::PluginMixins::Jdbc
  config_name "jdbc"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain" 

  # Statement to execute
  #
  # To use parameters, use named parameter syntax.
  # For example:
  #
  # [source, ruby]
  # ----------------------------------
  # "SELECT * FROM MYTABLE WHERE id = :target_id"
  # ----------------------------------
  #
  # here, ":target_id" is a named parameter. You can configure named parameters
  # with the `parameters` setting.
  config :statement, :validate => :string

  # Path of file containing statement to execute
  config :statement_filepath, :validate => :path

  # Hash of query parameter, for example `{ "target_id" => "321" }`
  config :parameters, :validate => :hash, :default => {}

  # Schedule of when to periodically run statement, in Cron format
  # for example: "* * * * *" (execute query every minute, on the minute)
  #
  # There is no schedule by default. If no schedule is given, then the statement is run
  # exactly once.
  config :schedule, :validate => :string
  
  # The mysql auto increment column
  config :mysql_auto_increment_column, :validate => :string

  # The url for elasticsearch
  config :elasticsearch_host, :validate => :string
  
  # The elasticsearch index to use when getting max_id 
  config :elasticsearch_index, :validate => :string
  
  # The type to use when storing rows in es
  config :elasticsearch_type, :validate => :string
  
  # Enable or disable logging for es client
  config :elasticsearch_logging, :validate => :boolean, :default => false
  
  # Path to file with last run time
  config :last_run_metadata_path, :validate => :string, :default => "#{ENV['HOME']}/.logstash_jdbc_last_run"

  # Whether the previous run state should be preserved
  config :clean_run, :validate => :boolean, :default => false

  # Whether to save state or not in last_run_metadata_path
  config :record_last_run, :validate => :boolean, :default => true

  public

  def register
    require "rufus/scheduler"
    prepare_jdbc_connection

    # load sql_last_start from file if exists
    if @clean_run && File.exist?(@last_run_metadata_path)
      File.delete(@last_run_metadata_path)
    elsif File.exist?(@last_run_metadata_path)
      @sql_last_start = YAML.load(File.read(@last_run_metadata_path))
    end

    unless @statement.nil? ^ @statement_filepath.nil?
      raise(LogStash::ConfigurationError, "Must set either :statement or :statement_filepath. Only one may be set at a time.")
    end

    @statement = File.read(@statement_filepath) if @statement_filepath
  end # def register

  def run(queue)
    if @schedule
      @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
      @scheduler.cron @schedule do
        execute_query(queue)
      end

      @scheduler.join
    else
      execute_query(queue)
    end
  end # def run

  def stop
    @scheduler.stop if @scheduler

    # update state file for next run
    if @record_last_run
      File.write(@last_run_metadata_path, YAML.dump(@sql_last_start))
    end

    close_jdbc_connection
  end

  private
  def get_max_aiid()
    #type = 'qf'
	type = @elasticsearch_type
	
    #aiid = 'aiid'
	aiid = @mysql_auto_increment_column
	
    #the_index = 'test_qf'
	the_index = @elasticsearch_index
	
    es_logging = @elasticsearch_logging
	
    #es_host = 'http://127.0.0.1:9200'
	es_host = @elasticsearch_host

    type_aiid = type + '.' + aiid
    q = '{
        "query": {
            "bool": { 
                "must": [
                    {
                        "range": {
                            "'+type_aiid+'": {
                                "gte": "0"
                            }
                        } 
                    }
                ] 
            }
        },
        "from": 0,
        "size": 1,
        "sort": [
            {
                "'+type_aiid+'": {
                    "order": "desc"
                }
            }
        ]
    }'

    # Connect to elastisearch
    client = Elasticsearch::Client.new host:es_host, log: es_logging

    # Verify health
    health = client.cluster.health
    if health['status'] == 'red'
        puts "Cluster health is bad!!! Returning -1"
        return -1
    end
   
    # Make refresh prior to query
    begin 
        client.indices.refresh index:the_index
    rescue
        puts "An error ocurred while refreshing index...returning -1"
        return -1
    end

    # Find max aiid
    begin
        res = JSON.parse \
            RestClient.get(es_host + '/' + the_index + '/' + type + '/_search',
                           params: { source: q})

		if res['hits']['hits'].length == 0
			puts "No documents of given type found. Returning 0"
			return 0
		end
		# We have a document - and know the max_id - return it
        return res['hits']['hits'][0]['_source'][aiid]
    rescue RestClient::ResourceNotFound
        # The index does not exist
        # This is fine - it will be created automatically
        puts "Failed getting max id(Index not there yet). Returning 0"
        return 0
    rescue
        puts "Non expected error ocurred. Returning -1"
        return -1
    end
  end
  
  

  def execute_query(queue)
    # update default parameters
    max_id = get_max_aiid()
    if max_id < 0
        return
    end

    @parameters['max_id'] = max_id
    execute_statement(@statement, @parameters) do |row|
      event = LogStash::Event.new(row)
      decorate(event)
      queue << event
    end
  end
end # class LogStash::Inputs::Jdbc
