module StatsHelper
  # セクション見出しに添える集計期間の表記。
  # Recently Bounced は直下のフォームに from/to が出ているため対象外。
  def stats_period_label(from, to)
    "#{from.strftime('%Y-%m-%d')} 〜 #{to.strftime('%Y-%m-%d')}"
  end

  # 上位 top 件を個別系列、残り全件の合計を 'etc' として返す。
  # 残りが空なら 'etc' 系列は追加しない（0 件の etc を出さない）。
  # collection は Hash（key => count）または [key, count] のソート済み配列のどちらでもよい。
  # 呼び出し元のコレクションは変更しない（drop/first はいずれも非破壊）。
  def chart_columns(collection, top: 3)
    pairs = collection.to_a
    columns = pairs.first(top)
    remainder = pairs.drop(top)
    remainder.empty? ? columns : columns + [['etc', remainder.sum {|_, v| v }]]
  end
end
