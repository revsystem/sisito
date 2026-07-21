#!/usr/bin/env ruby
require 'fileutils'
require 'sisimai'
require 'mysql2'
require 'tmpdir'

COLUMNS = %w(
  timestamp
  lhost
  rhost
  alias
  listid
  reason
  action
  subject
  messageid
  smtpagent
  hardbounce
  smtpcommand
  destination
  senderdomain
  feedbacktype
  diagnosticcode
  deliverystatus
  timezoneoffset
  addresser
  recipient
)

MAIL_DIR = '/root/Maildir/new'

def process(path, **options)
  Dir.mktmpdir do |tmpdir|
    FileUtils.mv(Dir["#{path}/*"], tmpdir)
    v = Sisimai.rise(tmpdir, **options) || []
    v.each {|e| yield(e) }
  end
end

def insert(mysql, data)
  hash = data.to_hash
  # Sisimai >= 5.5.0 removed the smtpagent/smtpcommand keys from #to_hash
  # (they were backward-compat aliases dropped after 5.4.x). Rebuild them from
  # their current equivalents so the bounce_mails columns stay populated
  # regardless of sisimai version.
  hash['smtpagent']   ||= hash['decodedby']
  hash['smtpcommand'] ||= hash['command']
  values = hash.values_at(*COLUMNS)
  addresseralias = data.addresser.alias
  addresseralias = data.addresser.address if addresseralias.empty?
  values << addresseralias
  columns = (COLUMNS + ['addresseralias', 'digest', 'created_at', 'updated_at']).join(?,)
  timestamp = values.shift
  values = (["FROM_UNIXTIME(#{timestamp})"] + values.map(&:inspect) + ['SHA1(recipient)', 'NOW()', 'NOW()']).join(?,)
  sql = "INSERT INTO bounce_mails (#{columns}) VALUES (#{values})"
  mysql.query(sql)
end

mysql = Mysql2::Client.new(host: 'mysql', username: 'root', database: 'sisito_development', reconnect: true)

process(MAIL_DIR) do |data|
  insert(mysql, data)
end
