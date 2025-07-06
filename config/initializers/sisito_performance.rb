# Sisito パフォーマンス設定

Rails.application.configure do
  # 大量データでのパフォーマンス向上設定
  
  # クエリタイムアウト設定（秒）
  config.sisito_query_timeout = 30
  
  # 統計処理の軽量化フラグ
  config.sisito_fast_stats = true
  
  # 大量データ判定閾値
  config.sisito_large_data_threshold = 100000
end