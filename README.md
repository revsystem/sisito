# Sisito

It is [sisimai](http://libsisimai.org/) collected data frontend.

## Screenshot

![Statistics](./public/Sisito_dashboard_01.png "Sisito_dashboard_01.png")  &nbsp; ![Bounce Mails](./public/Sisito_dashboard_02.png "Sisito_dashboard_02.png")

## Installation

```console
git clone https://github.com/revsystem/sisito.git
cd sisito
sudo apt-get update && sudo apt-get install -y default-libmysqlclient-dev libssl-dev libyaml-dev
bundle install
vi config/database.yml
bundle exec rails db:create db:migrate
bundle exec rails server
```

If you need to access the application from outside the server, you can run the following command. You can access the application from `http://<server-ip>:1080`.

```console
bundle exec rails server -p 1080 -b 0.0.0.0
```

### Using docker

```console
git clone https://github.com/revsystem/sisito.git
cd sisito
docker-compose build
docker-compose up
# console: http://localhost:3000
# mailcatcher: http://localhost:11080
# api: `curl localhost:8080/blacklist` (see https://github.com/revsystem/sisito-api#api)
```

## Recommended System Requirements

* Ruby 3.1.2 or later
* MySQL 8.0.36 or later

## Bounced Mail Collect Script Example

```ruby
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

MAIL_DIR = '/home/scott/Maildir/new'

def process(path, **options)
  Dir.glob("#{path}/**/*").each do |entry|
    next unless File.file?(entry)

    Dir.mktmpdir do |tmpdir|
      FileUtils.mv(entry, tmpdir)
      v = Sisimai.rise(tmpdir, **options) || []
      v.each {|e| yield(e) }
    end
  end
end

def insert(mysql, data)
  values = data.to_hash.values_at(*COLUMNS)
  addresseralias = data.addresser.alias
  addresseralias = data.addresser if addresseralias.empty?
  values << addresseralias.to_s
  columns = (COLUMNS + ['addresseralias', 'digest', 'created_at', 'updated_at']).join(?,)
  timestamp = values.shift
  values = (["FROM_UNIXTIME(#{timestamp})"] + values.map(&:inspect) + ['SHA1(recipient)', 'NOW()', 'NOW()']).join(?,)
  sql = "INSERT INTO bounce_mails (#{columns}) VALUES (#{values})"
  mysql.query(sql)
end

# sql:
#   INSERT INTO bounce_mails (
#     timestamp,
#     lhost,
#     rhost,
#     alias,
#     listid,
#     reason,
#     action,
#     subject,
#     messageid,
#     smtpagent,
#     hardbounce,
#     smtpcommand,
#     destination,
#     senderdomain,
#     feedbacktype,
#     diagnosticcode,
#     deliverystatus,
#     timezoneoffset,
#     addresser,
#     recipient,
#     addresseralias,
#     digest,
#     created_at,
#     updated_at
#   ) VALUES (
#     /* timestamp      */  FROM_UNIXTIME(1503152383),
#     /* lhost          */  "43b36f28aa95",
#     /* rhost          */  "",
#     /* alias          */  "user-1503152383@a.b.c",
#     /* listid         */  "",
#     /* reason         */  "hostunknown",
#     /* action         */  "failed",
#     /* subject        */  "subject-1503152383",
#     /* messageid      */  "20170819141943.A58CC35A@43b36f28aa95",
#     /* smtpagent      */  "MTA::Postfix",
#     /* hardbounce     */  0,
#     /* smtpcommand    */  "",
#     /* destination    */  "a.b.c",
#     /* senderdomain   */  "43b36f28aa95",
#     /* feedbacktype   */  "",
#     /* diagnosticcode */  "Host or domain name not found. Name service error for name=a.b.c type=AAAA: Host not found",
#     /* deliverystatus */  "5.4.4",
#     /* timezoneoffset */  "+0900",
#     /* addresser      */  "root@43b36f28aa95",
#     /* recipient      */  "user-1503152383@a.b.c",
#     /* addresseralias */  "root@43b36f28aa95",
#     /* digest         */  SHA1(recipient),
#     /* created_at     */  NOW(),
#     /* updated_at     */  NOW()
#   )

mysql = Mysql2::Client.new(host: 'db-server', username: 'root', database: 'sisito', reconnect: true)

process(MAIL_DIR) do |data|
  insert(mysql, data)
end
```

## List Blacklisted Recipients SQL Example

```sql
SELECT
  recipient
FROM
  bounce_mails bm
  LEFT JOIN whitelist_mails wm
    ON bm.recipient = wm.recipient
   AND bm.senderdomain = wm.senderdomain
WHERE
  bm.senderdomain = 'example.com'
  AND wm.id IS NULL
  /*
  AND bm.softbounce = 1
  AND bm.reason IN ('filtered')
  */
```

## Monitoring

```json
$ curl -s localhost:3000/status | jq .
{
  "start_time": "2017-08-19T22:36:08.887+09:00",
  "interval": 60,
  "count": {
    "all": 7,
    "reason": {
      "hostunknown": 7
    },
    "senderdomain": {
      "example.com": 7
    },
    "destination": {
      "any.not_exist_domain.com": 7
    }
  }
}
```

## Using Local Timezone

Please fix [config/application.rb](https://github.com/revsystem/sisito/blob/master/config/application.rb) as follows:

```ruby
module Sisito
  class Application < Rails::Application
    ...
    config.active_record.default_timezone = :local
    config.time_zone = "Tokyo"
    ...
```

## Customize Sisito

see [config/sisito.yml](https://github.com/revsystem/sisito/blob/master/config/sisito.yml)

## Related Links

* http://libsisimai.org
* https://github.com/winebarrel/sisito-api
