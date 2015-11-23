# Logstash JDBC Input Plugin - auto increment
This is a modified version of the logstash-input-jdbc plugin forked from here:

https://github.com/logstash-plugins/logstash-input-jdbc

## Goal
The goal is to optimize loading of events into elasticsearch from tables using an autoincrement column.

Using this approach I believe that we can keep tables in sync with an elasticsearch index more efficiently than using the @sql_last_start on time/date field.

State is kept in the elasticsearch index - not a seperate logstash state file.

## Input configuration
The plugin requires a few additional config elements in the input section(see logstash-mysql.conf for complete example):
```
  elasticsearch_host => "http://127.0.0.1:9200"
  elasticsearch_index => "bar"
  elasticsearch_type => "qf"
  elasticsearch_logging => true
  mysql_auto_increment_column => "aiid"
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
select * from foo where aiid>:max_id order by aiid
```
or if you want to load a huge table a little at a time:
```
select * from foo where aiid>:max_id order by aiid limit 10000
```
Surely we don´t need to use a seperate column for auto_increment - the primary key could also be used as long as it "auto increments".

## How it works
Before each execution of the sql statement, the plugin reads the max value stored in the elasticsearch index.
If the index is found the plugin uses the value as max_id in the sql query.

#### The elasticsearch query used

```
{
  "filter" : {
    "match_all" : { }
  },
  "sort": [
    {
      "aiid": {
        "order": "desc"
      }
    }
  ],
  "size": 1
}
```



#### A complete mysql->elasticsearch config example
```
input {
  jdbc {
    jdbc_driver_library => "mysql-connector-java-5.1.37-bin.jar"
    jdbc_driver_class => "com.mysql.jdbc.Driver"
    jdbc_connection_string => "jdbc:mysql://127.0.0.1:3306/foo"
    jdbc_validate_connection => true
    jdbc_user => "foo_user"
    jdbc_password => "foo_passwd"
    elasticsearch_host => "http://127.0.0.1:9200"
    elasticsearch_index => "bar"
    elasticsearch_type => "qf"
    elasticsearch_logging => true
    mysql_auto_increment_column => "aiid"
    schedule => "* * * * *"
    statement => "select aiid, id as foo_id, replace(value, '\\', '/') as path from foo_table where aiid>:max_id order by aiid limit 100000"
  }
}

output {
  elasticsearch {
    hosts => ["127.0.0.1:9200", "127.0.0.2:9200", "127.0.0.3:9200"]
    index => "bar"           # Must be the same as defined in the input config above
    document_type => "qf"    # Must be the same as elasticsearch_type in input config above
  }
}


```
## Limitations
If the table rows are changed, this plugin will not re-index those rows.
