import WebKit

// MARK: - Reader Mode
// Compact, self-contained readability-style extractor (NOT Mozilla Readability —
// see plan note). Scores block elements, picks the densest, strips chrome, and
// re-renders a themed article page in place.

enum ReaderMode {
    /// JS returns a JSON string: {title, byline, content}. Returns "" on failure.
    static let extractJS = """
    (function(){
      function textOf(n){return (n.innerText||'').replace(/\\s+/g,' ').trim();}
      // Link density = fraction of a block's text that lives inside <a> tags.
      // High density ⇒ navigation/menu, not article body.
      function linkDensity(n){
        var t=textOf(n).length||1,l=0;
        n.querySelectorAll('a').forEach(function(a){l+=(a.innerText||'').length;});
        return Math.min(l/t,1);
      }
      var JUNK='script,style,noscript,iframe,nav,footer,header,aside,form,button,svg,'
        +'[role=navigation],[role=complementary],[role=banner],[aria-hidden=true],'
        +'[class*=share],[class*=social],[class*=comment],[id*=comment],[class*=related],'
        +'[class*=newsletter],[class*=promo],[class*=advert],[class*=cookie],[class*=paywall]';
      function clean(n){
        n.querySelectorAll(JUNK).forEach(function(e){e.remove();});
        n.querySelectorAll('a').forEach(function(a){ if(!textOf(a)) a.remove(); });      // empty links
        n.querySelectorAll('div,span').forEach(function(e){ if(!textOf(e)&&!e.querySelector('img,figure,pre')) e.remove(); });
        return n;
      }
      function score(el){
        var t=textOf(el);
        if(t.length<180) return -1;
        var p=el.querySelectorAll('p').length;
        var s=t.length/80 + p*4 + (t.match(/[,.]/g)||[]).length*0.2;
        var c=((el.className||'')+' '+(el.id||'')).toLowerCase();
        if(/comment|footer|sidebar|nav|menu|share|related|promo|advert|cookie|masthead|widget/.test(c)) s-=60;
        if(/article|content|post|story|main|body|entry|page|read/.test(c)) s+=30;
        return s*(1-linkDensity(el));   // punish link-heavy blocks
      }
      var best=null,bs=0;
      // Prefer semantic containers; fall back to scoring generic blocks.
      var explicit=document.querySelector('article,[role=main],main');
      var cands = explicit ? [explicit]
        : Array.prototype.slice.call(document.querySelectorAll('article,main,section,div'));
      cands.forEach(function(el){var s=score(el); if(s>bs){bs=s;best=el;}});
      if(!best||bs<=0) best=document.body;
      var clone=clean(best.cloneNode(true));
      var h1=document.querySelector('h1');
      var title=(h1&&textOf(h1))||document.title||'';
      var bl=document.querySelector('[rel=author],.author,.byline,[itemprop=author]');
      var byline=bl?textOf(bl):'';
      if(!byline){var site=document.querySelector('meta[property="og:site_name"]'); if(site) byline=site.content||'';}
      return JSON.stringify({title:title.trim(),byline:byline.trim(),content:clone.innerHTML});
    })();
    """

    /// Extract the current page and load a themed reader document in place.
    /// `onBuild` receives the generated HTML so callers can cache it and re-load
    /// it after the tab is slept (loadHTMLString state doesn't survive suspend).
    static func enter(_ wv: WKWebView, theme: Theme, onBuild: @escaping (String) -> Void = { _ in }) {
        let base = wv.url
        wv.evaluateJavaScript(extractJS) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let content = obj["content"], !content.isEmpty else { return }
            let html = document(title: obj["title"] ?? "", byline: obj["byline"] ?? "",
                                 content: content, theme: theme)
            onBuild(html)
            wv.loadHTMLString(html, baseURL: base)
        }
    }

    private static func document(title: String, byline: String, content: String, theme: Theme) -> String {
        let p = theme.palette
        let bg = p.bg.hexString ?? "#15131b"
        let text = p.text.hexString ?? "#efeaf5"
        let dim = p.dim.hexString ?? "#a59cb3"
        let accent = theme.accentHex
        let fontSize = theme.density == .compact ? 17 : theme.density == .roomy ? 21 : 19
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html{background:\(bg);}
          body{max-width:720px;margin:0 auto;padding:64px 28px 120px;
               font:\(fontSize)px/1.7 -apple-system,Georgia,serif;color:\(text);}
          h1{font-size:1.9em;line-height:1.2;font-weight:600;margin:0 0 .2em;}
          .byline{color:\(dim);font-size:.8em;margin:0 0 2em;}
          a{color:\(accent);} img{max-width:100%;height:auto;border-radius:8px;}
          p{margin:0 0 1em;} pre,code{font-family:ui-monospace,monospace;}
          pre{background:rgba(127,127,127,.12);padding:12px;border-radius:8px;overflow:auto;}
          blockquote{border-left:3px solid \(accent);margin:1em 0;padding:.2em 1em;color:\(dim);}
          h2,h3{margin-top:1.6em;}
        </style></head><body>
        <h1>\(title)</h1>\(byline.isEmpty ? "" : "<div class=\"byline\">\(byline)</div>")
        \(content)</body></html>
        """
    }
}
