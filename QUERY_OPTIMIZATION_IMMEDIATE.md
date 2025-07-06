# 緊急クエリ最適化

## 現在の問題
- `uniq_count_by_sender`クエリが149秒間「Creating sort index」状態
- CASE文とCOUNT DISTINCTの組み合わせが重い

## 即座の対処法

### 1. 現在の重いクエリをキャンセル
```sql
-- MySQLに接続
mysql -u root -p sisito_development

-- 実行中のクエリを確認
SHOW FULL PROCESSLIST;

-- 重いクエリをキャンセル（プロセスID = 21）
KILL 21;
```

### 2. 一時的な設定変更
```ruby
# config/sisito.yml に以下を追加
shorten_stats: true
```

これにより重い統計処理を無効化できます。

### 3. マイグレーション適用
```bash
# 新しいインデックスを適用
bundle exec rails db:migrate

# アプリケーション再起動
bundle exec rails server
```

### 4. クエリ最適化の確認
最適化後のクエリは以下のように分割されます：

```sql
-- 最適化前（重い）
SELECT COUNT(DISTINCT recipient) AS count_recipient,
       CASE WHEN addresseralias = '' THEN addresser ELSE addresseralias END AS addresser_alias
FROM bounce_mails
GROUP BY addresser_alias;

-- 最適化後（軽い）
SELECT addresseralias, COUNT(DISTINCT recipient) 
FROM bounce_mails 
WHERE addresseralias != '' AND addresseralias IS NOT NULL
GROUP BY addresseralias;

SELECT addresser, COUNT(DISTINCT recipient) 
FROM bounce_mails 
WHERE addresseralias = '' OR addresseralias IS NULL
GROUP BY addresser;
```

## 期待される効果
- 149秒 → 5-10秒に短縮
- メモリ使用量の大幅削減
- 安定したレスポンス

## 完全な適用手順
1. 重いクエリをキャンセル
2. `shorten_stats: true`を設定
3. マイグレーション実行
4. 動作確認後、`shorten_stats: false`に戻す