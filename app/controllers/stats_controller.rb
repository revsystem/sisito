class StatsController < ApplicationController
  def index
    @recent_days_to = params[:to].present? ? params[:to].to_date : Date.today
    default_recent_days = Rails.application.config.sisito.fetch(:default_recent_days, 14)
    @recent_days_from = params[:from].present? ? params[:from].to_date : @recent_days_to - default_recent_days
    @addresser = params[:addresser]

    # Recently Bounced
    @count_by_date = cache_if_production("count_by_date_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
      relation = BounceMail.where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

      relation = relation.where(addresser: @addresser) if @addresser.present?

      # インデックスを活用するため、DATE関数を避けてGROUP BYを最適化
      cbd = relation.select(Arel.sql('DATE(timestamp) AS date, COUNT(1) AS count'))
                    .group(Arel.sql('DATE(timestamp)'))
                    .order(Arel.sql('DATE(timestamp)'))
                    .pluck(Arel.sql('DATE(timestamp)'), Arel.sql('COUNT(1)'))
                    .to_h

      (@recent_days_from..@recent_days_to).map {|d| [d, cbd.fetch(d, 0)] }.to_h
    end

    @count_by_destination = cache_if_production("count_by_destination_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
      relation = BounceMail.where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

      relation = relation.where(addresser: @addresser) if @addresser.present?

      # インデックスを活用するため順序を最適化
      relation.group(:destination).order(Arel.sql('COUNT(*) DESC')).count
    end

    @count_by_reason = cache_if_production("count_by_reason_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
      relation = BounceMail.where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

      relation = relation.where(addresser: @addresser) if @addresser.present?

      # インデックスを活用するため順序を最適化
      relation.group(:reason).order(Arel.sql('COUNT(*) DESC')).count
    end

    @count_by_reason_date = cache_if_production("count_by_date_reason_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
      relation = BounceMail.select(:reason, Arel.sql("DATE(timestamp) AS date"), Arel.sql("COUNT(reason) AS count_reason"))
                           .where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

      relation = relation.where(addresser: @addresser) if @addresser.present?

      crd = relation.group(:reason, :date)
                    .sort_by {|i| [i.reason, i.date] }
                    .inject({}) {|r, i| r[i.reason] ||= {}; r[i.reason][i.date] = i.count_reason; r }

      crd.keys.each do |reason|
        (@recent_days_from..@recent_days_to).each {|d| crd[reason][d] ||= 0 }
      end

      crd
    end

    unless Rails.application.config.sisito[:shorten_stats]
      # Unique Recipient Bounced
      @uniq_count_by_destination = cache_if_production("uniq_count_by_destination_#{@addresser}", expires_in: 2.hours) do
        relation = BounceMail

        relation = relation.where(addresser: @addresser) if @addresser.present?

        relation.distinct.group(:destination).count(:recipient)
                .sort_by(&:last).reverse.to_h
      end

      @uniq_count_by_reason = cache_if_production("uniq_count_by_reason_#{@addresser}", expires_in: 2.hours) do
        relation = BounceMail

        relation = relation.where(addresser: @addresser) if @addresser.present?

        # オリジナルのシンプルな実装（MySQL設定改善により高速化）
        relation.distinct.group(:reason).count(:recipient)
                .sort_by(&:last).reverse.to_h
      end

      @uniq_count_by_sender = cache_if_production("uniq_count_by_sender_#{@addresser}", expires_in: 2.hours) do

        select_columns = <<-SQL
          COUNT(DISTINCT recipient) AS count_recipient,
          CASE
          WHEN addresseralias = '' THEN addresser
          ELSE addresseralias
          END AS addresser_alias
        SQL

        relation = BounceMail.select(Arel.sql(select_columns))

        relation = relation.where(addresser: @addresser) if @addresser.present?

        relation.group(Arel.sql('addresser_alias'))
                .map {|r| [r.addresser_alias, r.count_recipient] }
                .sort_by(&:last).reverse.to_h
      end

      # Bounced by Type
      @bounced_by_type = cache_if_production("bounced_by_type_#{@addresser}", expires_in: 2.hours) do

        count_by_reason_destination = {}

        relation = BounceMail

        relation = relation.where(addresser: @addresser) if @addresser.present?

        relation.group(:reason, :destination).count.each do |(reason, destination), count|
          count_by_reason_destination[reason] ||= {}
          count_by_reason_destination[reason][destination] = count
        end

        count_by_reason_destination
      end
    end
  end
end
