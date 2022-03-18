# How does `summarize` compare to `load_async`?

`load_async` is cool, and it serves an almost completely different use case—you can't even use it with calculations out of the box.

⭐️ `load_async` is for "I know I'm going to need these `Post` records, but I probably won't actually do anything with them till render, so start loading them in the background now while I do some other work."

If there's only one collection to load for a given controller action, the benefits will be very modest. But if you have (e.g.) 2 collections to load, `load_async` lets you hide the load time of the faster one inside the slower one, since the queries will run simultaneously—at the cost of using an additional database connection. The most straightforward wins for `load_async`, IMO, are when you have one slow-ish load and several quick queries or you have a slow-ish load *and* you will have to wait on some other 3rd-party API. (In both cases, start the slow load first with `load_async`.)

⭐️ `summarize` is for "Over the last 30 days, for each subreddit that I'm a moderator of, I need to count how many `Post` were created, and I also need to count how many of them ended up with negative karma, and I also need to see, grouped by date, what percentage of posts ended up with `karma > :karma_threshold`, and I also want to know the average number of comments per post, for all posts with karma >= 0, grouped by day of the week."

`summarize` can get all that for you in a single query and return the data in a useful shape. See [use_case_moderator_dashboard](./use_case_moderator_dashboard.md) for how it might be done.
