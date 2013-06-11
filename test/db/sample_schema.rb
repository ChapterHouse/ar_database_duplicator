ActiveRecord::Schema.define(:version => 20100610212120) do

  create_table "users", :force => true do |t|
    t.string   "name",                            :limit => 123,      :default => ""
    t.string   "email",                           :limit => 231
    t.string   "crypted_password",                :limit => 80
    t.string   "salt",                            :limit => 124
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "remember_token",                  :limit => 93
    t.datetime "remember_token_expires_at"
    t.integer  "session_timeout",                 :default => 18,     :null => false
    t.string   "login",                                               :null => false
    t.string   "label"
    t.string   "first_name"
    t.string   "last_name"
    t.string   "activation_code"
    t.datetime "activated_at"
    t.boolean  "agree_to_terms",                 :default => false,  :null => false
    t.string   "zip_code"
    t.string   "phone_number"
    t.string   "facebook_id"
    t.integer  "timezone"
    t.string   "token"
    t.string   "address_line_1"
    t.string   "address_line_2"
    t.string   "city"
    t.string   "state"
    t.string   "country"
    t.integer  "birth_year"
    t.string   "gender"
  end

  add_index "users", ["activation_code"], :name => "activation_code"
  add_index "users", ["email"], :name => "email"
  add_index "users", ["login"], :name => "login"
  add_index "users", ["name"], :name => "name"
  add_index "users", ["remember_token"], :name => "remember_token"

  create_table "zip_codes", :force => true do |t|
    t.string "zip"
    t.string "city"
    t.string "state",     :limit => 2
    t.float  "latitude"
    t.float  "longitude"
  end

end

