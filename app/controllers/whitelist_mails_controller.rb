class WhitelistMailsController < ApplicationController
  before_action :set_whitelist_mail, only: [:destroy]

  def index
    @whitelist_mails = WhitelistMail.all
  end

  def new
    @whitelist_mail = WhitelistMail.new
  end

  def create
    @whitelist_mail = WhitelistMail.new(whitelist_mail_params)

    if @whitelist_mail.save
      redirect_to whitelist_mails_path, notice: 'Whitelist mail was successfully created.'
    else
      render :new
    end
  end

  def register
    whitelist_mail = WhitelistMail.new(whitelist_mail_params)

    unless WhitelistMail.exists?(recipient: whitelist_mail.recipient)
      whitelist_mail.save!
    end

    redirect_to whitelist_mails_path
  end

  def destroy
    @whitelist_mail.destroy
    redirect_to whitelist_mails_url, notice: 'Whitelist mail was successfully destroyed.'
  end

  private

  def set_whitelist_mail
    @whitelist_mail = WhitelistMail.find(params[:id])
  end

  def whitelist_mail_params
    params.require(:whitelist_mail).permit(:recipient, :senderdomain)
  end
end