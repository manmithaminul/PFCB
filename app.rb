# app.rb - PFCB Environment Verification
require 'sinatra'

set :port, 4567

get '/' do
  "PFCB (Personal Finance Chat Bot) Server Online - Ruby 4.0.6 + Sinatra"
end