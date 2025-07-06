# frozen_string_literal: true

Kaminari.configure do |config|
  # 大量データでのパフォーマンス向上のため、ページサイズを小さくする
  config.default_per_page = 20
  config.max_per_page = 100
  
  # ページネーションの最大ページ数を制限してパフォーマンスを向上
  config.max_pages = 1000
  
  # 大量データでのページネーション改善のため、ウィンドウサイズを調整
  config.window = 2
  config.outer_window = 1
  config.left = 1
  config.right = 1
end