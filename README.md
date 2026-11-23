# 🎬 Media Tracker

A small, dependency-free web app to track the movies and TV shows you own.

- **Library** – movies and shows, owned or on your wishlist
- **Missing seasons** – compares the seasons you own with the seasons TMDB says have aired
- **Suggestions** – "you might like" picks based on your library, plus missing movies from franchises you already own
- **Music** – your digital music library (`Artist\Album (Year)\tracks`), grouped by artist, kept up to date automatically by the sync script
- **Vinyl** – your record collection and wishlist, searched via [MusicBrainz](https://musicbrainz.org/) with covers from the Cover Art Archive (no key needed)
- **Private** – your data lives in your browser's localStorage; nothing is uploaded anywhere. Export/import JSON backups.

Metadata and posters come from [TMDB](https://www.themoviedb.org/). This product uses the TMDB API but is not endorsed or certified by TMDB.

## Use it

1. Get a free TMDB API key: <https://www.themoviedb.org/settings/api>
2. Open `index.html` in a browser (or host it, see below) and paste the key under **Settings**. The key stays in your browser only.
3. Add titles with **+ Add**, or import your existing library (below).
4. For TV shows, open a title and tap the seasons you own. The **Missing seasons** tab does the rest.
5. On **Suggestions**, press *Generate* to fetch recommendations.
6. On **Vinyl**, press **+ Add**, search an artist or album, and mark it owned or wishlist. Add notes (pressing, condition) by opening a record.

## Share it with family and friends (phone app + read-only view)

It's a plain website, so a home-screen shortcut is just a link that opens it in the browser. Open your github.io link on a phone, then:
- **iPhone:** Safari → Share → *Add to Home Screen*
- **Android:** Chrome menu → *Add to Home screen* (choose *Create shortcut* if asked)

Anyone who opens the link with no library of their own sees your published snapshot, read-only (no editing, no keys). To publish or refresh it:

1. In the app (on your own copy): **Settings → Export shared snapshot**.
2. Run `scripts\Publish-Snapshot.ps1`. It moves the file to `shared\library.json` in this repo.
3. Commit and push with GitHub Desktop. Within a few minutes the shared view updates.

The snapshot contains your titles, posters, owned seasons, wishlist and vinyl. It leaves out your API key, hidden suggestions and vinyl notes. **Anyone with the link can see it**, so only publish what you're happy to share. On a new device, "Manage my own library" at the bottom of the shared view switches to the editable app.

## Fully automatic updates (Windows)

`scripts\Sync-Site.ps1` does everything in one go: scans your Jellyfin folders, matches new titles on TMDB, refreshes season data for your shows, rewrites `shared\library.json`, then commits and pushes it. If nothing changed it does nothing. Wishlist and vinyl entries already in the snapshot are preserved.

One-time setup:
1. Give it your TMDB key without putting it in the repo, in PowerShell: `setx TMDB_API_KEY "your-key"` (then open a new window).
2. Try it: `.\scripts\Sync-Site.ps1 -DryRun` (writes nothing), then `.\scripts\Sync-Site.ps1`. The first real run may open a GitHub sign-in window; sign in once.
3. Schedule it daily: `.\scripts\Register-SyncTask.ps1 -Time 03:00`. If the PC is off at that time, it runs when the PC is next on. The task runs while you're signed in to Windows.

Progress and errors are written to `scripts\sync.log` (git-ignored). Remove the schedule with `Unregister-ScheduledTask -TaskName MediaTrackerSync -Confirm:$false`.

The same run also updates the **Music** tab from `E:\Jellyfin_Music\LoadedtoServer` (change it with `-MusicPath`). Albums are matched on MusicBrainz for covers, at most 200 new albums per run (about a second each), so a large collection fills in over a few days. The music list mirrors the disk, so renamed or removed albums disappear on the next run.

Vinyl records and wishlist items are added in the app and live in your browser, so those still need **Settings → Export shared snapshot** + `Publish-Snapshot.ps1` when you change them.

## Keep it up to date (manual)

A web page can't read your hard drive, so after adding movies or shows, rescan:

1. Double-click `scripts\Update-Library.cmd` (or run `scripts\Scan-Library.ps1`). It rewrites `library.json`.
2. In the app: **Settings → Import scan / backup…** and pick `library.json`.

Re-importing is safe: new titles are matched and added, and owned seasons are updated for titles you already have (no TMDB lookups, nothing is removed). Titles you delete from disk stay in the app until you remove them.


## Publish on GitHub Pages

```bash
git init
git add .
git commit -m "Media Tracker"
git branch -M main
git remote add origin https://github.com/<you>/media-tracker.git
git push -u origin main
```

Then in the repo: **Settings → Pages → Deploy from a branch → `main` / root**. Each visitor uses their own browser storage and their own TMDB key, so nothing private is committed.

## Notes

- Specials (season 0) are ignored. Seasons without an air date or airing in the future are shown as "upcoming", not missing.
- Browser storage is per-browser: use **Export backup** to move data between devices.
