import Foundation

/// JavaScript that walks the *rendered* DOM and collects every image and video
/// it can find, resolving relative URLs against the page and returning a JSON
/// array of `{ url, kind, poster, width, height }`.
///
/// Because this runs against the live page inside the web view, it sees content
/// that loaded after login and content injected by JavaScript.
enum MediaScanner {
    static let script: String = #"""
    (function () {
      function abs(u) {
        if (!u) return null;
        try { return new URL(u, document.baseURI).href; } catch (e) { return null; }
      }

      var out = [];
      var seen = {};

      function add(url, kind, poster, w, h) {
        url = abs(url);
        if (!url) return;
        if (url.indexOf('data:') === 0) return;        // skip inline base64
        if (url.indexOf('blob:') === 0) return;        // blobs aren't downloadable here
        var key = kind + '|' + url;
        if (seen[key]) return;
        seen[key] = 1;
        out.push({ url: url, kind: kind, poster: abs(poster), width: w || null, height: h || null });
      }

      function largestFromSrcset(srcset) {
        var best = null, bestW = 0;
        srcset.split(',').forEach(function (part) {
          var seg = part.trim().split(/\s+/);
          var u = seg[0];
          var w = seg[1] ? parseInt(seg[1], 10) : 0;
          if (w >= bestW) { bestW = w; best = u; }
        });
        return best;
      }

      // <img>
      document.querySelectorAll('img').forEach(function (img) {
        var src = img.currentSrc || img.src;
        if (img.srcset) { var best = largestFromSrcset(img.srcset); if (best) src = best; }
        add(src, 'image', null, img.naturalWidth, img.naturalHeight);
      });

      // <source> inside <picture> and <video>
      document.querySelectorAll('source').forEach(function (s) {
        var parent = s.parentElement;
        var kind = (parent && parent.tagName === 'VIDEO') ? 'video' : 'image';
        if (s.srcset) { var best = largestFromSrcset(s.srcset); add(best, kind, null, null, null); }
        if (s.src) add(s.src, kind, null, null, null);
      });

      // <video>
      document.querySelectorAll('video').forEach(function (v) {
        var src = v.currentSrc || v.src;
        add(src, 'video', v.poster, v.videoWidth, v.videoHeight);
      });

      // CSS background images
      document.querySelectorAll('*').forEach(function (el) {
        var bg = window.getComputedStyle(el).backgroundImage;
        if (bg && bg.indexOf('url(') !== -1) {
          var m = bg.match(/url\((["']?)([^"')]+)\1\)/);
          if (m && m[2]) add(m[2], 'image', null, null, null);
        }
      });

      // Links that point directly at a media file
      var exts = /\.(jpe?g|png|gif|webp|bmp|svg|avif|mp4|mov|webm|m4v|avi|mkv)(\?|#|$)/i;
      var videoExts = /\.(mp4|mov|webm|m4v|avi|mkv)(\?|#|$)/i;
      document.querySelectorAll('a[href]').forEach(function (a) {
        if (exts.test(a.href)) {
          add(a.href, videoExts.test(a.href) ? 'video' : 'image', null, null, null);
        }
      });

      return JSON.stringify(out);
    })();
    """#
}
