# 🎬 Media Tracker

A small, dependency-free web app to track the movies and TV shows you own.

- **Library** – movies and shows, owned or on your wishlist
- **Missing seasons** – compares the seasons you own with the seasons TMDB says have aired
- **Suggestions** – "you might like" picks based on your library, plus missing movies from franchises you already own
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

The app is an installable web app. Open your github.io link on a phone, then:
- **iPhone:** Safari → Share → *Add to Home Screen*
- **Android:** Chrome menu → *Install app* / *Add to Home Screen*

Anyone who opens the link with no library of their own sees your published snapshot, read-only (no editing, no keys). To publish or refresh it:

1. In the app (on your own copy): **Settings → Export shared snapshot**.
2. Run `scripts\Publish-Snapshot.ps1`. It moves the file to `shared\library.json` in this repo.
3. Commit and push with GitHub Desktop. Within a few minutes the shared view updates.

The snapshot contains your titles, posters, owned seasons, wishlist and vinyl. It leaves out your API key, hidden suggestions and vinyl notes. **Anyone with the link can see it**, so only publish what you're happy to share. On a new device, "Manage my own library" at the bottom of the shared view switches to the editable app.

## Keep it up to date

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
