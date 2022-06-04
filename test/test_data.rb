require_relative "./test_helper"

class Person < ActiveRecord::Base
  establish_connection adapter: "sqlite3", database: ":memory:"
  connection.create_table table_name, force: true do |t|
    t.string :name
    t.integer :number_of_cats
  end

  scope :with_long_name, ->(gt: 20) { where("length(#{table_name}.name) > ?", gt) }

  SILLY_WORDS = %w[Abibliophobia Absquatulate Batrachomyomachy Bibble Billingsgate Bloviate Borborygm Boustrophedon Bowyang Brouhaha Bumbershoot Bumfuzzle Canoodle Cantankerous Cattywampus Cockamamie Codswallop Collop Collywobbles Comeuppance Crapulence Donnybrook Doozy Erinaceous Fard Fatuous Flibbertigibbet Fuddy-duddy Gardyloo Gobbledygook Godwottery Gonzo Goombah Gubbins Hobbledehoy Hocus-pocus Impignorate Lickety-split Lollygag Malarkey Mollycoddle Mugwump Namby-pamby Nincompoop Nudiustertian Ornery Pandiculation Pauciloquent Pettifogger Quire Ratoon Rigmarole Shenanigan Sialoquent Skedaddle Smellfungus Snickersnee Snollygoster Snool TroglodyteWabbit Widdershins Xertz Yarborough Zoanthropy]

  def self.generate_random!
    create!(name: SILLY_WORDS.sample(2).join(" "), number_of_cats: rand(0..3))
  end
end

Person.transaction do
  500.times { Person.generate_random! }
end
