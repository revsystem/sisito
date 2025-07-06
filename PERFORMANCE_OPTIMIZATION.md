# パフォーマンス最適化ガイド

## 実施された最適化

### 1. データベースインデックスの最適化

新しいマイグレーション `20250705000001_add_performance_indexes_to_bounce_mails.rb` で以下のインデックスを追加：

```sql
-- 実行: bundle exec rails db:migrate
CREATE INDEX idx_timestamp_addresser ON bounce_mails(timestamp, addresser);
CREATE INDEX idx_addresser_timestamp ON bounce_mails(addresser, timestamp);
CREATE INDEX idx_reason_timestamp ON bounce_mails(reason, timestamp);
CREATE INDEX idx_recipient_senderdomain_timestamp ON bounce_mails(recipient, senderdomain, timestamp);
CREATE INDEX idx_addresser_reason_timestamp ON bounce_mails(addresser, reason, timestamp);
CREATE INDEX idx_recipient_senderdomain_join ON bounce_mails(recipient, senderdomain);
CREATE INDEX idx_hardbounce_timestamp ON bounce_mails(hardbounce, timestamp);
CREATE INDEX idx_destination_timestamp ON bounce_mails(destination, timestamp);
```

### 2. アプリケーションレベルの最適化

#### StatsController の改善
- キャッシュ時間を5分から30分に延長
- GROUP BYクエリの最適化
- ORDER BYを事前に適用してRubyでのソートを削減

#### BounceMailsController の改善
- ORDER BYにIDを追加してページネーションを安定化
- 複合インデックスを活用した検索条件の最適化

#### Kaminari設定の最適化
- デフォルトページサイズを20に調整
- 最大ページ数を1000に制限
- ページネーションウィンドウサイズを最適化

## 期待される効果

### 高優先度の改善（即座に効果）
- **日付範囲での検索**: 50-70%の高速化
- **宛先・理由別の統計**: 40-60%の高速化
- **キャッシュ効果**: 統計画面の表示時間を大幅短縮

### 中優先度の改善（継続的効果）
- **複合検索**: 30-50%の高速化
- **ページネーション**: 安定したパフォーマンス
- **JOIN処理**: 20-40%の高速化

## 数十万件データでの推定パフォーマンス

### 最適化前
- 統計画面の初回表示: 15-30秒
- 検索結果の表示: 10-20秒
- ページネーション: 5-10秒

### 最適化後
- 統計画面の初回表示: 3-8秒
- 検索結果の表示: 2-5秒
- ページネーション: 1-2秒

## 運用上の推奨事項

### 1. 定期的なメンテナンス
```sql
-- インデックスの最適化（月1回実行）
OPTIMIZE TABLE bounce_mails;

-- テーブル統計の更新（週1回実行）
ANALYZE TABLE bounce_mails;
```

### 2. 監視すべきクエリ
```sql
-- 遅いクエリを特定
SHOW FULL PROCESSLIST;

-- 実行計画の確認
EXPLAIN SELECT * FROM bounce_mails WHERE timestamp >= '2025-01-01' ORDER BY timestamp DESC LIMIT 20;
```

### 3. 将来の改善案（オプション）

#### 読み取り専用レプリカの導入
```yaml
# config/database.yml
production:
  primary:
    <<: *default
    database: sisito_production
  replica:
    <<: *default
    database: sisito_production
    host: replica_host
    replica: true
```

#### 古いデータのアーカイブ
```ruby
# 1年以上古いデータをアーカイブテーブルに移動
# 定期実行バッチ処理として実装
```

#### 統計データの事前集計
```ruby
# 日次/週次/月次の統計データを事前計算
# バックグラウンドジョブで実行
```

## 適用方法

1. **マイグレーションの実行**
   ```bash
   bundle exec rails db:migrate
   ```

2. **アプリケーションの再起動**
   ```bash
   bundle exec rails server
   ```

3. **効果の確認**
   - 統計画面の表示速度を測定
   - 検索機能の応答時間を確認
   - ページネーションの動作を検証

## 注意事項

- マイグレーション実行時は一時的にパフォーマンスが低下します
- 大量データがある場合、マイグレーションに時間がかかる可能性があります
- 本番環境では事前にテスト環境で検証してください