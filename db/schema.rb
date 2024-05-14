# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2022_10_15_175608) do
  create_table "bounce_mails", id: :integer, charset: "utf8mb3", force: :cascade do |t|
    t.datetime "timestamp", precision: nil, null: false
    t.string "lhost", null: false
    t.string "rhost", null: false
    t.string "alias", null: false
    t.string "listid", null: false
    t.string "reason", null: false
    t.string "action", null: false
    t.string "subject", null: false
    t.string "messageid", null: false
    t.string "smtpagent", null: false
    t.boolean "hardbounce", null: false
    t.string "smtpcommand", null: false
    t.string "destination", null: false
    t.string "senderdomain", null: false
    t.string "feedbacktype", null: false
    t.text "diagnosticcode", null: false
    t.string "deliverystatus", null: false
    t.string "timezoneoffset", null: false
    t.string "addresser", null: false
    t.string "addresseralias", null: false
    t.string "recipient", null: false
    t.string "digest", default: "", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["addresser"], name: "idx_addresser_senderdomain"
    t.index ["destination"], name: "idx_destination"
    t.index ["digest"], name: "idx_digest"
    t.index ["hardbounce", "recipient"], name: "idx_hardbounce_recipient"
    t.index ["messageid"], name: "idx_messageid"
    t.index ["reason", "recipient"], name: "idx_reason_recipient"
    t.index ["recipient"], name: "idx_recipient"
    t.index ["senderdomain"], name: "idx_senderdomain"
    t.index ["timestamp"], name: "idx_timestamp"
  end

  create_table "whitelist_mails", id: :integer, charset: "utf8mb3", force: :cascade do |t|
    t.string "recipient", default: "", null: false
    t.string "senderdomain", default: "", null: false
    t.string "digest", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["created_at"], name: "idx_created_at"
    t.index ["digest"], name: "index_whitelist_mails_on_digest"
    t.index ["recipient", "senderdomain"], name: "idx_recipient_senderdomain", unique: true
  end

end
