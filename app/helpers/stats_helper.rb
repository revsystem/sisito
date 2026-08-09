module StatsHelper
  # セクション見出しに添える集計期間の表記。
  # Recently Bounced は直下のフォームに from/to が出ているため対象外。
  def stats_period_label(from, to)
    "#{from.strftime('%Y-%m-%d')} 〜 #{to.strftime('%Y-%m-%d')}"
  end
end
