require_relative "./test_helper"

database = ":memory:"
ENV["DATABASE_URL"] = "sqlite3:#{database}"
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database)
stdout_logger = Logger.new($stdout)
# ActiveRecord::Base.logger = stdout_logger # Usually don't want to see all the inserts, but if you're changing them you might

SILLY_WORDS = %w[Abibliophobia Absquatulate Batrachomyomachy Bibble Billingsgate Bloviate Borborygm Boustrophedon Bowyang Brouhaha Bumbershoot Bumfuzzle Canoodle Cantankerous Cattywampus Cockamamie Codswallop Collop Collywobbles Comeuppance Crapulence Donnybrook Doozy Erinaceous Fard Fatuous Flibbertigibbet Fuddy-duddy Gardyloo Gobbledygook Godwottery Gonzo Goombah Gubbins Hobbledehoy Hocus-pocus Impignorate Lickety-split Lollygag Malarkey Mollycoddle Mugwump Namby-pamby Nincompoop Nudiustertian Ornery Pandiculation Pauciloquent Pettifogger Quire Ratoon Rigmarole Shenanigan Sialoquent Skedaddle Smellfungus Snickersnee Snollygoster Snool TroglodyteWabbit Widdershins Xertz Yarborough Zoanthropy]
COLORS = %w[Red Orange Yellow Green Blue Indigo Violet]

ActiveRecord::Schema.define do
  create_table :colors, force: true do |t|
    t.string :name
  end

  create_table :people, force: true do |t|
    t.string :name
    t.integer :number_of_cats
    t.belongs_to :favorite_color, foreign_key: {to_table: :colors}
  end

  connection.create_table :clubs, force: true do |t|
    t.string :name
  end

  create_join_table :clubs, :people
end

class Color < ActiveRecord::Base
  has_many :fans, class_name: "Person"
end

class Person < ActiveRecord::Base
  belongs_to :favorite_color, class_name: "Color"
  has_and_belongs_to_many :clubs

  scope :with_long_name, ->(gt: 20) { where("length(#{table_name}.name) > ?", gt) }

  def self.generate_random!
    create!(
      name: SILLY_WORDS.sample(2).join(" "),
      number_of_cats: rand(0..3),
      favorite_color_id: rand(1..COLORS.length)
    )
  end
end

class Club < ActiveRecord::Base
  has_and_belongs_to_many :members, class_name: "Person"

  SILLY_WORDS = %w[Abibliophobia Absquatulate Batrachomyomachy Bibble Billingsgate Bloviate Borborygm Boustrophedon Bowyang Brouhaha Bumbershoot Bumfuzzle Canoodle Cantankerous Cattywampus Cockamamie Codswallop Collop Collywobbles Comeuppance Crapulence Donnybrook Doozy Erinaceous Fard Fatuous Flibbertigibbet Fuddy-duddy Gardyloo Gobbledygook Godwottery Gonzo Goombah Gubbins Hobbledehoy Hocus-pocus Impignorate Lickety-split Lollygag Malarkey Mollycoddle Mugwump Namby-pamby Nincompoop Nudiustertian Ornery Pandiculation Pauciloquent Pettifogger Quire Ratoon Rigmarole Shenanigan Sialoquent Skedaddle Smellfungus Snickersnee Snollygoster Snool TroglodyteWabbit Widdershins Xertz Yarborough Zoanthropy]

  def self.generate_random!(members)
    create!(name: SILLY_WORDS.sample(2).join(" "), members: members)
  end
end

Color.transaction do
  COLORS.each_with_index { |name, i| Color.create(name: name, id: i + 1) }
end

Person.transaction do
  500.times { Person.generate_random! }
end

Club.transaction do
  people = Person.all
  30.times { Club.generate_random!(people.sample(rand(3..60))) }
end

# Often helpful to see the queries the tests run
ActiveRecord::Base.logger = stdout_logger
