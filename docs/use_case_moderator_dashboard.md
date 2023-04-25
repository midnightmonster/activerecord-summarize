
# Using `summarize` for a moderator dashboard at reddit (in my imagination)

I'm an only-occasional reddit user and not a moderator at all, but let's imagine we're building a dashboard for moderators with activity and engagement stats for each subreddit they moderate. Let's suppose a straightforward Rails-y schema and a Postgres database. (I have no inside knowledge about how reddit actually works, and maybe at reddit's scale you'd need an entirely different approach.)

## Requirements

For each subreddit that a user moderates, the user should see these stats with respect to the last 30 days:

- count of how many posts were created
- count of how many posts from this period were buried, i.e., ended up with negative karma
- grouped by post creation date, the percentage of posts that ended up being popular, where popular means having a karma score greater than a per-subreddit-configured threshold
- grouped by post creation day of the week, the average number of comments per non-buried post
  
  > *Below, grouping by day of the week is handled with `.group("EXTRACT(DOW FROM posts.created_at)")`*

## Background

Before we get into the dashboard, someone must have written something for selecting popular posts already, right? Here it is!

```ruby
class Post < ApplicationModel
  # Grab our subreddit's popularity_threshold directly: no need to join through subreddits
  has_one :popularity_threshold_setting, -> { where(key: "popularity_threshold") },
    class_name: 'Setting', foreign_key: :subreddit_id, primary_key: :subreddit_id
  scope :popular, -> { left_joins(:popularity_threshold_setting)
    .where("posts.karma >= coalesce(settings.value,?)", DEFAULT_POPULAR_THRESHOLD) }
end
```

## Without `summarize`

You might start with something like this:

```ruby
def dashboard
  @subreddits = current_user.moderated_subreddits
  @subreddit_stats = subreddits.each_with_object({}) do |subreddit, all_stats|
    stats = all_stats[subreddit.id] = {}
    posts = subreddit.posts.where(created_at: 30.days.ago..).order(:created_at)
    stats[:posts_created] = posts.count
    stats[:buried_posts] = posts.where(karma: ...0).count
    daily_posts = posts.group("posts.created_at::date")
    daily_popular = daily_posts.popular.count
    daily_total = daily_posts.count
    stats[:daily_popular_rate] = daily_total.map {|k,v| [k,(daily_popular[k]||0).to_f / v] }.to_h
    dow_not_buried = posts.where(karma: 0..).group("EXTRACT(DOW FROM posts.created_at)")
    dow_posts = dow_not_buried.count
    dow_comments = dow_not_buried.sum(:comments_count)
    stats[:dow_avg_comments] = dow_posts.map {|k,v| [k,(dow_comments[k]||0).to_f / v] }.to_h
  end
end
```

This code is straightforward and easy to read and reason about, but for a user who moderates 3 subreddits, just this part of the dashboard is going to involve 18 database queries. And anything else we want to add to the subreddit stats will be another 1-2 queries per subreddit. So if you're building this dashboard, as requirements evolve over time, it's going to get slower and slower, and eventually you're going to push back on requirements and/or rewrite the whole action as a wall of hand-crafted SQL and another wall of ruby code to get the data back into the right shape.

## With `summarize`

Or you could do it **with `summarize`** and get identical results in a single query.

This is the more-advanced `.group(*cols).summarize` mode that has no direct ActiveRecord equivalent: just as above, `@subreddit_stats` will  be a hash with `subreddit_id` keys, and each value will be a hash with a couple of simple count values and a couple grouped calculations. But to do this with `ActiveRecord` alone, we had to iterate a list, run queries, and build the `@subreddit_stats` hash ourself.

I've also given one requirement that implies a join, so you can see how that works just a touch differently with `summarize`.

```ruby
def dashboard
  @subreddits = current_user.moderated_subreddits
  # Join :popularity_threshold_setting before .summarize to use it within the summarize block.
  # If you forget, `daily_posts.popular.count` will raise `Unsummarizable` with a helpful message.
  all_posts = Post.where(subreddit: @subreddits.select(:id)).where(created_at: 30.days.ago..)
                  .left_joins(:popularity_threshold_setting).order(:created_at)
  @subreddit_stats = all_posts.group(:subreddit_id).summarize do |posts, with_resolved|
    daily_posts = posts.group("posts.created_at::date")
    dow_not_burried = posts.where(karma: 0..).group("EXTRACT(DOW FROM posts.created_at)")
    {
      posts_created: posts.count,
      buried_posts: posts.where(karma: ...0).count,
      daily_popular_rate: with_resolved[
          daily_posts.popular.count,
          daily_posts.count
        ] do |popular, total|
          total.map { |date, count| [date, (popular[date]||0).to_f / count] }.to_h
        end,
      dow_avg_comments: with_resolved[
          dow_not_buried.sum(:comments_count),
          dow_not_buried.count
        ] do |comments, posts|
          posts.map { |dow, count| [dow, (comments[dow]||0).to_f / count] }.to_h
        end
    }
  end
end
```

Since `summarize` runs a single query that visits each relevant `posts` row just once, adding additional calculations is pretty close to free.

Even with the mental overhead of needing to join outside the block and use `with_resolved` to combine calculations (see [README](../README.md) for details), I think this is still easy to read, write, and reason about, and it beats the heck out of walls of SQL. What do you think?
