# Launch Window 🛰️

A daily three-stage game for the crew. New mission every day at midnight Eastern.

1. **Liftoff:** 60 seconds to name as many things in a category as you can. Answers nobody else in the crew gave earn bonus thrust.
2. **Signal Lock:** a satellite downlinks a clue about a mystery thing every orbit. Guess early for more points.
3. **Landing:** three estimation questions. Too high is redshifted, too low is blueshifted.

Play at `https://oliviacaper.github.io/launch-window/#<crew-code>`.

## How it runs
- **Hosting:** GitHub Pages serves `index.html` from this repo.
- **Database:** Supabase stores missions and scores (`db/schema.sql`). Missions are only readable on their own day, so upcoming answers never ship in this repo.
- **Content:** a nightly scheduled task writes and fact-checks upcoming missions and adds them to the database. Unique indexes make sure no Liftoff category, Signal Lock answer or Landing question is ever reused.
