# Physical leaderboards

Each of the eight bases can show the same three global top-ten boards without
running 24 independent leaderboard loops.

## Selected boards

| Board | Tag | What the score means |
|---|---|---|
| Top Coins | `LeaderboardCoins` | Current saved Coins balance |
| Top Income | `LeaderboardIncome` | Coins earned per second by the player's entire squishy pad |
| Most Playtime | `LeaderboardPlaytime` | Cumulative time played across sessions |

Income is more representative than “highest squishy”: it measures the whole
pad and directly communicates earning power. Playtime is useful long-term
recognition. Level is not used because the current game has no gameplay path
that awards XP, so every player would remain level 1.

## Studio setup

For each base, put three board models in Workspace. In Studio's Tag Editor,
give the root of each model exactly one of the tags above. Across eight bases,
there should be eight instances with each tag and 24 tagged instances total.

The tagged object can be a Model, BasePart, SurfaceGui, or the ScrollingFrame
itself. The service searches recursively, so intermediate model names are not
significant. Each tagged board needs this UI structure:

```text
BoardModel [one leaderboard tag]
  ...
    ScrollingFrame
      RankTemplate1
      RankTemplate2
      RankTemplate3
      RankTemplate4
```

Each rank template must be a GuiObject and should contain TextLabels named:

- `UserName`
- `Amount`
- `Rank`

Templates 1–3 style the medal positions. `RankTemplate4` is reused for ranks
4–10. The service hides the authored templates and creates the ten live rows.
It leaves layouts and other decorations in the ScrollingFrame untouched.

An optional TextLabel named `LeaderboardTitle` (or `Title`) is filled with the
default category title. Set a string attribute named `LeaderboardTitle` on a
tagged board to override that title.

The old standalone `Workspace.Leaderboard` is no longer special. If it should
remain active, give it one of the three tags as well.

## Synchronization and cost

- Current-player scores publish on join, leave, shutdown, and every 60 seconds.
- The server reads each category once every 60 seconds: three sorted reads,
  whether there are three boards or 24.
- A category snapshot is fanned out to all eight matching physical boards, so
  those copies always render identical ranks from the same refresh.
- Usernames are resolved for all three categories together and cached for an
  hour.
- Each board has only ten generated rows, for 240 live rows across the map.

`Leaderboard_Income_v1` and `Leaderboard_Playtime_v1` are new OrderedDataStores
and fill as players join. Coins continues using the existing `Coins` store, so
its historical rankings are preserved.
