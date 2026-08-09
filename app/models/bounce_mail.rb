class BounceMail < ApplicationRecord
  # timestamp が from 〜 to（to 当日を含む）に入るレコードに絞る。
  # from / to はカレンダー日（Date）を渡す。時刻付きオブジェクトを渡すと
  # 「その時刻 + 1 日」が上限になり、当日を丸ごと含める意図からずれる。
  # 上限の +1.day は呼び出し側に書かせず、境界のずれを構造的に防ぐ。
  scope :within_period, ->(from, to) {
    where('timestamp >= ? AND timestamp < ?', from, to + 1.day)
  }

  def mask_recipient
    user, domain = self.recipient.split('@', 2)
    user.gsub!(/./, '*')
    [user, domain].join(?@)
  end

  def addresser_or_alias
    if self.addresseralias.blank?
      self.addresser
    else
      self.addresseralias
    end
  end

  def link
    mail_link = Rails.application.config.sisito[:mail_link]

    if mail_link
      mail_link % {digest: self.digest}
    else
      nil
    end
  end
end
