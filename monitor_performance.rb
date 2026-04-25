#!/usr/bin/env ruby
# パフォーマンス監視スクリプト

require 'mysql2'

class SisitoPerformanceMonitor
  def initialize
    @client = Mysql2::Client.new(
      host: 'localhost',
      username: 'bounce',
      password: 'bounce',
      database: 'sisito_development'
    )
  end

  def check_performance
    puts "=== Sisito Performance Monitor ==="
    puts "実行時刻: #{Time.now}"
    puts

    check_slow_queries
    check_table_status
    check_index_usage
    check_memory_usage
  end

  private

  def check_slow_queries
    puts "【実行中のクエリ】"
    result = @client.query("SHOW FULL PROCESSLIST")
    
    slow_queries = result.select { |row| row['Time'].to_i > 5 }
    
    if slow_queries.empty?
      puts "✅ 5秒以上のクエリはありません"
    else
      slow_queries.each do |query|
        puts "⚠️  #{query['Time']}秒: #{query['Info'][0..100]}..."
      end
    end
    puts
  end

  def check_table_status
    puts "【テーブル状況】"
    result = @client.query(<<~SQL)
      SELECT 
        table_name,
        ROUND(((data_length + index_length) / 1024 / 1024), 2) AS 'Size_MB',
        table_rows,
        ROUND((index_length / (data_length + index_length)) * 100, 2) AS 'Index_Ratio'
      FROM information_schema.tables 
      WHERE table_schema = 'sisito_development' AND table_name = 'bounce_mails'
    SQL

    result.each do |row|
      puts "📊 #{row['table_name']}: #{row['Size_MB']}MB, #{row['table_rows']}行, インデックス比率#{row['Index_Ratio']}%"
    end
    puts
  end

  def check_index_usage
    puts "【重要インデックス状況】"
    indexes = [
      'idx_timestamp_addresser',
      'idx_reason_timestamp',
      'idx_recipient_senderdomain_timestamp',
      'idx_reason_destination'
    ]
    
    indexes.each do |idx|
      result = @client.query(<<~SQL)
        SELECT COUNT(*) as count FROM information_schema.statistics 
        WHERE table_schema = 'sisito_development' 
        AND table_name = 'bounce_mails' 
        AND index_name = '#{idx}'
      SQL
      
      if result.first['count'] > 0
        puts "✅ #{idx} - 作成済み"
      else
        puts "❌ #{idx} - 未作成"
      end
    end
    puts
  end

  def check_memory_usage
    puts "【メモリ使用状況】"
    variables = ['innodb_buffer_pool_size', 'tmp_table_size', 'sort_buffer_size']
    
    variables.each do |var|
      result = @client.query("SHOW VARIABLES LIKE '#{var}'")
      if result.first
        value = result.first['Value']
        puts "💾 #{var}: #{format_bytes(value.to_i)}"
      end
    end
    puts
  end

  def format_bytes(bytes)
    units = ['B', 'KB', 'MB', 'GB']
    unit_index = 0
    size = bytes.to_f

    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end

    "#{size.round(2)} #{units[unit_index]}"
  end
end

# 実行
if __FILE__ == $0
  monitor = SisitoPerformanceMonitor.new
  monitor.check_performance
end