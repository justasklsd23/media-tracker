# 🎬 Media Tracker

A small, dependency-free web app to track the movies and TV shows you own.

- **Library** – movies and shows, owned or on your wishlist
- **Missing seasons** – compares the seasons you own with the seasons TMDB says have aired
- **Suggestions** – "you might like" picks based on your library, plus missing movies from franchises you already own
- **Private** – your data lives in your browser's localStorage; nothing is uploaded anywhere. Export/import JSON backups.

Metadata and posters come from [TMDB](https://www.themoviedb.org/). This product uses the TMDB API but is not endorsed or certified by TMDB.

## Use it

1. Get a free TMDB API key: <https://www.themoviedb.org/settings/api>
2. Open `index.html` in a browser (or host it, see below) and paste the key under **Settings**. The key stays in your browser only.
3. Add titles with **+ Add**, or import your existing library (below).
4. For TV shows, open a title and tap the seasons you own. The **Missing seasons** tab does the rest.
5. On **Suggestions**, press *Generate* to fetch recommendations.


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
