// Optional real-browser geometry check. Dependencies/executable are explicit;
// this does not install a browser or count emulation as AnkiMobile proof.
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { createRequire } from "node:module";
import { addonPath, cardIdScript, scratchpadFragment, textSizeScript } from "./harness.mjs";

assert.ok(process.env.PLAYWRIGHT_MODULE_PATH, "provide PLAYWRIGHT_MODULE_PATH");
assert.ok(process.env.CHROMIUM_PATH, "provide CHROMIUM_PATH");
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE_PATH);
const output = resolve(process.argv[2] || "/tmp/anki-scratchpad-measurements");
await mkdir(output, { recursive:true });
const css = await readFile(resolve(addonPath, "../managed-types/study-basic/style.css"), "utf8");
const nativeCSS = "html{height:100%}body{margin:0}textarea:focus{outline:2px solid blue;outline-offset:2px}button{box-shadow:0 1px 2px #0002}.fancy button:hover{background:linear-gradient(white,#fcfcfc);border:1px solid #c4c4c4;box-shadow:0 2px 2px #0002;transition:box-shadow 180ms linear}";
const question = '<article class="rehab-card" data-anki-scratchpad-card><p class="question">CPU는 어떻게 같은 명령을 다시 실행할까?</p></article><div class="anki-cid-copy" data-anki-cid="123456789"></div>';
const explanation = '<span hidden data-anki-scratchpad-answer></span><hr id="answer"><p class="answer">PC를 반복 구간의 주소로 갱신한다.</p>' +
  Array.from({ length:50 }, (_, i) => `<p>합성 해설 ${i}: 본문과 입력칸은 독립적으로 스크롤한다.</p>`).join("");
const script = scratchpadFragment.match(/<script>([\s\S]*)<\/script>/)[1];
const fragmentCSS = scratchpadFragment.match(/<style>([\s\S]*)<\/style>/)[1];
const browser = await chromium.launch({ executablePath:process.env.CHROMIUM_PATH, headless:true });
const reports = [];
try {
  const screens=[[320,568,true],[375,667,true],[390,844,true],[430,932,true],
    [844,390,true],[860,650,false],[1440,900,false]];
  const cases=screens.flatMap(screen=>screen[2]
    ? [[...screen,false],[...screen,true]] : [[...screen,true]]);
  cases.push([860,650,false,true,true]);
  for (const [width,height,mobile,qaWrapper,previousOpen=false] of cases) {
    for (const scale of [0.8,1,1.4]) {
      const page = await browser.newPage({ viewport:{ width,height }, isMobile:mobile, hasTouch:mobile });
      const errors = [];
      page.on("pageerror", error => errors.push(String(error)));
      // The physical AnkiMobile body has a transform. A fixed descendant then
      // uses the short/long body as its containing block instead of the screen.
      const mobileHostCSS=mobile ? "body{transform:translateZ(0)}" : "";
      const html = `<!doctype html><html${mobile ? ' class="iphone"' : ""}><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>${nativeCSS}\n${mobileHostCSS}\n${css}\n${fragmentCSS}</style></head><body class="card fancy">${qaWrapper ? `<main id="qa">${question}</main>` : question}</body></html>`;
      await page.setContent(html);
      const edges=()=>page.locator('.question').evaluate(element=>({left:element.getBoundingClientRect().left,right:element.getBoundingClientRect().right}));
      const originalEdges=await edges();
      // Qt may retain the previous card's html class when the next script
      // initializes. Its already-split body box is not the original card box.
      if(previousOpen) await page.evaluate(()=>document.documentElement.classList.add('anki-scratchpad-open'));
      await page.evaluate(cardIdScript);
      await page.evaluate(textSizeScript);
      await page.evaluate(script);
      await page.evaluate(scale => document.documentElement.style.setProperty("--anki-text-scale",String(scale)),scale);
      await page.waitForFunction(() => !!document.querySelector(".anki-scratchpad"));
      const inspect = () => page.evaluate(() => {
        const ui = document.querySelector(".anki-scratchpad");
        const qa = document.querySelector("#qa") || document.body;
        const input = ui.querySelector("textarea");
        const panel = ui.querySelector(".anki-scratchpad__panel");
        const style = getComputedStyle(input);
        return { view:{ width:innerWidth,height:innerHeight },body:document.body.getBoundingClientRect().toJSON(),
          panel:panel.getBoundingClientRect().toJSON(), qa:qa.getBoundingClientRect().toJSON(),
          input:input.getBoundingClientRect().toJSON(),font:parseFloat(style.fontSize),
          outline:style.outlineStyle,shadow:style.boxShadow,bottomBorder:getComputedStyle(panel).borderBottomWidth,
          scrollWidth:document.documentElement.scrollWidth };
      });
      const before = await inspect();
      assert.ok(Math.abs(before.panel.left)<1 && Math.abs(before.panel.right-width)<1, "full width");
      assert.ok(Math.abs(before.panel.bottom-height)<1, "flush bottom");
      assert.ok(Math.abs(before.panel.height-height/3)<1,"initial pad is one third of the screen");
      assert.deepEqual(await edges(),originalEdges,"open preserves original card horizontal padding");
      if (!mobile) {
        assert.ok(Math.abs(before.body.height-height)<1, "body fills viewport");
        assert.ok(Math.abs(before.qa.bottom-before.panel.top)<1, "reader and pad meet");
      }
      assert.equal(before.bottomBorder,"0px");
      assert.equal(before.scrollWidth,width);
      assert.ok(Math.abs(before.font-(mobile ? Math.max(16,16*scale):17*scale))<0.1,"shared scale with mobile focus zoom floor");
      await page.locator("textarea").fill("한글 회상\n".repeat(80));
      const focused = await inspect();
      assert.equal(focused.outline,"none");
      assert.equal(focused.shadow,"none");
      if (!mobile && scale===1) {
        const button=page.locator('[data-action="collapse"]');
        const beforeHover=await button.boundingBox();
        await button.hover();
        assert.deepEqual(await button.boundingBox(),beforeHover,"hover does not change the hit area");
        const hover=await button.evaluate(element => {
          const rect=element.getBoundingClientRect(),group=element.parentElement.getBoundingClientRect();
          const style=getComputedStyle(element,"::after");
          return {group:group.toJSON(),top:rect.top+parseFloat(style.top),bottom:rect.bottom-parseFloat(style.bottom),
            left:rect.left+parseFloat(style.left),right:rect.right-parseFloat(style.right),color:style.backgroundColor,
            background:getComputedStyle(element).backgroundImage,shadow:getComputedStyle(element).boxShadow,
            border:getComputedStyle(element).borderTopWidth};
        });
        assert.ok(hover.top>=hover.group.top && hover.bottom<=hover.group.bottom,"hover stays inside the tool group vertically");
        assert.ok(hover.left>=hover.group.left && hover.right<=hover.group.right,"hover stays inside the tool group horizontally");
        assert.equal(hover.color,"rgb(232, 237, 243)","subtle icon-cell hover tint");
        assert.equal(hover.background,"none","native hover gradient does not leak through");
        assert.equal(hover.shadow,"none","native fancy hover shadow does not leak through");
        assert.equal(hover.border,"0px","native hover border does not change the button");
        await page.mouse.move(0,0);
      }
      if (mobile && scale===1) {
        const handle=page.locator('[role="separator"]');
        const grip=await handle.boundingBox();
        await page.mouse.move(grip.x+grip.width/2,grip.y+grip.height/2);
        await page.mouse.down();
        await page.mouse.move(grip.x+grip.width/2,grip.y+grip.height/2-40,{steps:4});
        await page.mouse.up();
        const moved=await handle.boundingBox();
        assert.ok(Math.abs(moved.y-grip.y+40)<1,"drag moves the visible grip by the touch distance");
        assert.ok(Math.abs((await inspect()).panel.bottom-height)<1,"resizing stays attached to the viewport");
        const clear=page.locator('[data-action="clear"]');
        const beforeClear=await clear.boundingBox();
        await clear.click();
        assert.equal(await page.locator("textarea").inputValue(),"","clear survives pointer-induced input blur");
        assert.deepEqual(await clear.boundingBox(),beforeClear,"mobile toolbar stays still when the input blurs");
        await page.locator("textarea").fill("한글 회상\n".repeat(80));
      }
      await page.evaluate(({question,explanation,script}) => {
        (document.querySelector("#qa")||document.body).innerHTML = question+explanation;
        eval(script);
        document.querySelector("#answer").scrollIntoView();
      }, { question,explanation,script });
      const independent = await page.evaluate(mobile => {
        const qa=document.querySelector("#qa"),input=document.querySelector("textarea");
        const old=mobile?document.body.scrollTop:qa.scrollTop;input.scrollTop=input.scrollHeight;
        return { before:old,after:mobile?document.body.scrollTop:qa.scrollTop,input:input.scrollTop,answer:document.querySelector("#answer").getBoundingClientRect().top };
      },mobile);
      if(mobile) assert.ok(Math.abs((await inspect()).panel.bottom-height)<1,"long answers cannot move the fixed pad below the screen");
      assert.ok(independent.before>0,"native answer scroll works inside reader");
      assert.equal(independent.before,independent.after);
      assert.ok(independent.input>0,"textarea scrolls independently");
      await page.locator('[data-action="collapse"]').click();
      assert.deepEqual(await edges(),originalEdges,"collapse preserves original card horizontal padding");
      await page.locator(".anki-scratchpad__launch").click();
      assert.deepEqual(await edges(),originalEdges,"reopen preserves original card horizontal padding");
      assert.ok(await page.locator("textarea").inputValue(),"reopen retains text");
      await page.evaluate(() => document.body.classList.add("nightMode"));
      await page.evaluate(script);
      assert.equal(await page.locator("textarea").evaluate(element=>getComputedStyle(element).backgroundColor),"rgb(31, 41, 51)");
      if (scale===1) await page.screenshot({ path:resolve(output,`scratchpad-${width}x${height}-${qaWrapper?'qa':'body'}-${previousOpen?'reused':'fresh'}.png`) });
      reports.push({ width,height,mobile,qaWrapper,previousOpen,scale,before,independent,errors });
      assert.deepEqual(errors,[]);
      await page.close();
    }
  }
  // Keyboard geometry is synthetic: physical AnkiMobile is a separate gate.
  const page = await browser.newPage({ viewport:{width:390,height:844},isMobile:true,hasTouch:true });
  await page.setContent(`<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}\n${fragmentCSS}</style></head><body class="card"><main id="qa">${question}</main></body></html>`);
  await page.evaluate(() => {
    const vv=new EventTarget();Object.assign(vv,{width:320,height:300,offsetLeft:30,offsetTop:80});
    Object.defineProperty(window,"visualViewport",{value:vv,configurable:true});
  });
  await page.evaluate(script);
  const offset = await page.locator(".anki-scratchpad__panel").boundingBox();
  assert.ok(Math.abs(offset.x-30)<1,"horizontal pan applies once");
  assert.ok(Math.abs(offset.y+offset.height-380)<1,"pad ends above synthetic keyboard");
  reports.push({ syntheticVisualViewport:true,offset });
  await page.close();
  const phone=await browser.newPage({viewport:{width:430,height:715},isMobile:true,hasTouch:true});
  const context=Array.from({length:50},(_,i)=>'<p class="context-line">Synthetic context '+i+'</p>').join("");
  await phone.setContent('<!doctype html><html class="iphone"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{transform:translateZ(0)}'+css+'\n'+fragmentCSS+'</style></head><body class="card">'+question+context+'<hr id="answer"><p>Answer anchor</p></body></html>');
  await phone.evaluate(()=>{
    const vv=new EventTarget();Object.assign(vv,{width:430,height:715,offsetLeft:0,offsetTop:0});
    Object.defineProperty(window,"visualViewport",{value:vv,configurable:true});
    // Force a real outer-document pan even when the product locks overflow.
    // Dispatching viewport events alone cannot catch the reading-position bug.
    const spacer=document.createElement("div");spacer.style.height="2400px";
    spacer.dataset.nativePanSimulator="true";document.documentElement.append(spacer);
  });
  await phone.evaluate(script);
  const reading=()=>phone.evaluate(()=>({
    marker:document.querySelectorAll('.context-line')[12].getBoundingClientRect().top,
    reader:document.body.scrollTop,outer:scrollY,
    pad:document.querySelector('.anki-scratchpad__panel').getBoundingClientRect().toJSON(),
    geometry:document.documentElement.style.cssText,
  }));
  await phone.evaluate(()=>{const marker=document.querySelectorAll('.context-line')[12];document.body.scrollTop=marker.offsetTop-80;});
  const beforeKeyboard=await reading();
  await phone.evaluate(async()=>{
    document.querySelector('textarea').focus();
    visualViewport.height=438;visualViewport.offsetTop=277;
    visualViewport.dispatchEvent(new Event('resize'));
    window.scrollTo(0,277);
    await new Promise(resolve=>requestAnimationFrame(resolve));
  });
  const withKeyboard=await reading();
  assert.equal(withKeyboard.outer,277,"native-pan simulator actually moves the outer document");
  assert.equal(withKeyboard.marker,beforeKeyboard.marker,"keyboard pan preserves the visible reading marker");
  assert.equal(withKeyboard.reader,beforeKeyboard.reader,"keyboard resize preserves the question scroll position");
  assert.ok(Math.abs(withKeyboard.pad.height-146)<1,"keyboard uses the chosen one-third ratio");
  assert.ok(Math.abs(withKeyboard.pad.bottom-438)<1,"pad stays above the keyboard");
  await phone.evaluate(async()=>{
    for(const height of [438,715,438]){
      Object.defineProperty(window,'innerHeight',{value:height,configurable:true});
      dispatchEvent(new Event('resize'));visualViewport.dispatchEvent(new Event('scroll'));
      await new Promise(resolve=>requestAnimationFrame(resolve));
    }
  });
  assert.deepEqual(await reading(),withKeyboard,"native pan does not jitter the split geometry or reading position");
  await phone.evaluate(()=>document.getElementById('answer').scrollIntoView());
  const anchored=await reading();
  assert.ok(anchored.reader>withKeyboard.reader,"answer anchor scrolls the question pane");
  assert.equal(anchored.outer,withKeyboard.outer,"answer anchor does not move the outer document");
  await phone.evaluate(async()=>{
    document.querySelector('textarea').blur();
    visualViewport.height=715;visualViewport.offsetTop=0;
    visualViewport.dispatchEvent(new Event('resize'));
    await new Promise(resolve=>requestAnimationFrame(resolve));
    document.querySelector('[data-action="collapse"]').click();
    // Real AnkiMobile can inflate VV/innerHeight after transferring a long
    // answer to document scrolling while clientHeight stays at 715px.
    visualViewport.height=829;
    Object.defineProperty(window,'innerHeight',{value:829,configurable:true});
    visualViewport.dispatchEvent(new Event('resize'));
    await new Promise(resolve=>requestAnimationFrame(resolve));
  });
  assert.equal(await phone.evaluate(()=>document.documentElement.clientHeight),715,
    "the native-pan fixture retains the measured layout viewport height");
  const collapsedLauncher=await phone.locator('.anki-scratchpad__launch').boundingBox();
  assert.ok(collapsedLauncher.y>=0 && collapsedLauncher.y+collapsedLauncher.height<=715-11,
    "collapsed launcher stays inside the real view after native document scrolling");
  await phone.locator('.anki-scratchpad__launch').click();
  const reopened=await reading();
  assert.ok(Math.abs(reopened.pad.bottom-715)<1,"reopening also ignores the inflated visual viewport");
  reports.push({mobileManagedReading:true,beforeKeyboard,withKeyboard,anchored,collapsedLauncher,reopened});
  await phone.close();
  await writeFile(resolve(output,"measurements.json"),JSON.stringify(reports,null,2)+"\n");
  console.log(`PASS: ${reports.length} geometry cases; screenshots and measurements: ${output}`);
} finally { await browser.close(); }
