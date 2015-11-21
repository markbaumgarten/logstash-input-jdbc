# Logstash JDBC Input Plugin - auto increment
This is a modified version of the logstash-input-jdbc plugin forked from here:

https://github.com/logstash-plugins/logstash-input-jdbc

## Goal
The goal is to optimize loading of events into elasticsearch from tables using an autoincrement column.

Using this approach I believe that we can keep tables in sync with an elasticsearch index more efficiently than using the @sql_last_start on time/date field.

State is kept in the elasticsearch index - not a seperate logstash state file.

## Input configuration
The plugin requires three additional config elements in the input section:
```
  # The mysql auto increment column
  config :mysql_auto_increment_column, :validate => :string

  # The url for elasticsearch
  config :elasticsearch_hosts, :validate => :string
  
  # The elasticsearch index to use when getting max_id 
  config :elasticsearch_index, :validate => :string
  ```
  
## Example

A table created like this(not tested since i dont have my hands on a (mysql) terminal, but I think it explains enough):
```
create table foo(
   foo_id integer primary key,
   name varchar(255),
   .....other columns....
   aiid integer auto_increment
);
```
Then the sql string in the logstash config should be:
```
select * from foo where aiid>:max_id
```
or if you want to load a huge table a little at a time:
```
select * from foo where aiid>:max_id limit 10000
```
Surely we don´t need to use a seperate column for auto_increment - the primary key could also be used as long as it "auto increments".

## Limitations
If the table rows are changed, this plugin will not re-index those rows.

## How it works
Before each execution of the sql statement, the plugin reads the max value stored in the elasticsearch index.
If the index is found the plugin uses the value as max_id in the sql query.

Here´s a more complete input config example:
```
input {
	jdbc {
	    jdbc_driver_library => "/path/to/mysql-connector-java-5.1.33-bin.jar"
	    jdbc_driver_class => "com.mysql.jdbc.Driver"
	    jdbc_connection_string => "jdbc:mysql://host:port/database"
	    jdbc_user => "user"
	    jdbc_password => "password"
	    statement => "select * from foo where aiid > :max_id limit 10000"
	    
	    # No longer used:
	    # jdbc_paging_enabled => "true"
	    # jdbc_page_size => "50000"
	
	    # New config elements:
	    mysql_auto_increment_column => "aiid"
	    # Im not a ruby developer...wanted to use multiple hosts....but for now only a single host works:
	    elasticsearch_hosts => "127.0.0.1:9200"
	    elasticsearch_index => "myindex" 
	}
}
```
