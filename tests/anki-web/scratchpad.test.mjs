import assert from "node:assert/strict";
import test from "node:test";
import { harness, scratchpadScript } from "./harness.mjs";

const card = (id = "123456789", back = false) =>
  `${back ? '<span hidden data-anki-scratchpad-answer></span>' : ""}<article class="rehab-card" data-anki-scratchpad-card><p class="question">긴 문제</p><span data-anki-cid="${id}"></span></article>${back ? '<hr id="answer"><p>해설</p>' : ""}`;
function setup({ mobile = false, qa = true } = {}) {
  const h = harness(qa ? `<div id="qa">${card()}</div>` : card(), { mobile, preload:false });
  h.window.scrollTo = () => {};
  h.window.eval(scratchpadScript);
  const ui = () => h.document.querySelector(".anki-scratchpad");
  const input = () => ui().querySelector("textarea");
  const action = name => ui().querySelector(`[data-action="${name}"]`).click();
  const open = () => ui().querySelector("button").click();
  const write = value => { input().value = value; input().dispatchEvent(new h.window.Event("input", { bubbles:true })); };
  const render = async (id, back = false) => {
    (h.document.getElementById("qa") || h.document.querySelector(".anki-scratchpad-reader") || h.document.body).innerHTML = card(id, back);
    h.window.eval(scratchpadScript);
    await h.flush();
  };
  const key = (key, options = {}) => {
    const event = new h.window.KeyboardEvent("keydown", { key, bubbles:true, cancelable:true, ...options });
    h.document.activeElement.dispatchEvent(event);
    return event;
  };
  return { ...h, ui, input, action, open, write, render, key,
    isOpen:() => h.document.documentElement.classList.contains("anki-scratchpad-open") };
}

test("collapse/reopen retains multiline literal text and focuses synchronously", () => {
  const h = setup();
  try {
    h.open();
    assert.equal(h.document.activeElement, h.input());
    const literal = "한글 회상\nconst x = '<img src=x onerror=alert(1)>';\n  2 < 3";
    h.write(literal); h.action("collapse");
    assert.equal(h.isOpen(), false);
    assert.equal(h.ui().querySelector(".anki-scratchpad__dot").hidden, false);
    h.open();
    assert.equal(h.input().value, literal);
    assert.equal(h.ui().querySelector("img"), null);
    assert.equal(h.document.activeElement, h.input());
  } finally { h.close(); }
});

test("FrontSide/back re-execution preserves the chosen closed state and editable text", async () => {
  const h = setup();
  try {
    h.open(); h.write("분기 명령은 PC를 바꾼다");
    h.action("collapse");
    await h.render("123456789", true);
    h.window.eval(scratchpadScript);
    assert.equal(h.document.querySelectorAll(".anki-scratchpad").length, 1);
    assert.equal(h.input().value, "분기 명령은 PC를 바꾼다");
    assert.equal(h.input().readOnly, false);
    assert.equal(h.isOpen(), false);
    assert.notEqual(h.document.activeElement, h.input());
    h.open(); h.write("뒷면에서도 수정");
    assert.equal(h.input().value, "뒷면에서도 수정");
  } finally { h.close(); }
});

test("next card, retry and undo clear text while retaining the session ratio", async () => {
  const h = setup();
  try {
    h.open(); h.write("A");
    const handle = h.ui().querySelector('[role="separator"]');
    handle.dispatchEvent(new h.window.KeyboardEvent("keydown", { key:"End", bubbles:true }));
    await h.render("123456790");
    assert.equal(h.input().value, "");
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "65");
    h.open(); h.write("B");
    await h.render("123456790", true);
    await h.render("123456790");
    assert.equal(h.input().value, "");
    h.open(); h.write("B again");
    await h.render("123456790", true);
    await h.render("123456789");
    assert.equal(h.input().value, "");
  } finally { h.close(); }
});

test("hiding or deactivating the application retains current text", () => {
  const h = setup();
  try {
    h.open(); h.write("아직 생각 중");
    h.document.dispatchEvent(new h.window.Event("visibilitychange"));
    h.window.dispatchEvent(new h.window.Event("blur"));
    h.window.dispatchEvent(new h.window.Event("focus"));
    assert.equal(h.input().value, "아직 생각 중");
    assert.equal(h.isOpen(), true);
  } finally { h.close(); }
});

test("same-card fresh front clears the draft; same DOM script re-execution preserves it", async () => {
  for (const qa of [true, false]) {
    const h = setup({ mobile:!qa, qa });
    try {
      h.open(); h.write("Undo 직전의 새 답안");
      h.ui().querySelector('[role="separator"]').dispatchEvent(new h.window.KeyboardEvent("keydown", { key:"End", bubbles:true }));
      h.action("collapse");
      await h.render("123456789");
      assert.equal(h.input().value, "");
      assert.equal(h.isOpen(), false);
      assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "65");
      h.open(); h.write("일반 앱 복귀");
      h.document.dispatchEvent(new h.window.Event("visibilitychange"));
      h.window.eval(scratchpadScript);
      await h.flush();
      assert.equal(h.input().value, "일반 앱 복귀");
      assert.equal(h.document.querySelectorAll(".anki-scratchpad").length, 1);
      assert.equal(h.ui().parentElement, qa ? h.document.body : h.document.documentElement);
    } finally { h.close(); }
  }
});

test("staged FrontSide on the answer does not look like same-card question Undo", async () => {
  const h = setup();
  try {
    h.open(); h.write("정답 공개까지 남겨야 하는 답안");
    h.document.getElementById("qa").innerHTML = '<span hidden data-anki-scratchpad-answer></span>' + card();
    h.window.eval(scratchpadScript);
    await h.flush();
    assert.equal(h.input().value, "정답 공개까지 남겨야 하는 답안");
    assert.notEqual(h.document.activeElement, h.input());
    h.document.getElementById("qa").insertAdjacentHTML("beforeend", '<hr id="answer"><p>해설</p>');
    h.window.eval(scratchpadScript);
    await h.flush();
    assert.equal(h.input().value, "정답 공개까지 남겨야 하는 답안");
    assert.equal(h.isOpen(), true);
  } finally { h.close(); }
});

test("focused scratchpad buttons isolate reviewer keys while separator keyboard resizing works", () => {
  const h = setup();
  try {
    let native = 0;
    h.document.addEventListener("keydown", () => native++);
    h.ui().querySelector("button").focus();
    h.key(" "); h.key("Enter"); h.key("e");
    h.open();
    h.ui().querySelector('[role="separator"]').focus();
    h.key("u"); h.key("1"); h.key("End");
    assert.equal(native, 0);
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "65");
  } finally { h.close(); }
});

test("unmanaged cards suspend the UI but preserve the session open state and size", async () => {
  const h = setup();
  try {
    h.open(); h.write("남기지 않을 답");
    h.ui().querySelector('[role="separator"]').dispatchEvent(new h.window.KeyboardEvent("keydown", { key:"End", bubbles:true }));
    h.document.getElementById("qa").innerHTML = '<p>다른 노트 유형</p><span data-anki-cid="123456790"></span>';
    await h.flush();
    assert.equal(h.ui(), null);
    assert.equal(h.document.documentElement.classList.contains("anki-scratchpad-open"), false);
    await h.render("123456789");
    assert.equal(h.input().value, "");
    assert.equal(h.isOpen(), true);
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "65");
  } finally { h.close(); }
});

test("a fresh session opens at one third without automatically focusing the input", () => {
  const h = setup();
  try {
    assert.equal(h.isOpen(), true);
    assert.notEqual(h.document.activeElement, h.input());
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "33");
  } finally { h.close(); }
});

test("pagehide discards all session state without storage writes", () => {
  const h = setup();
  try {
    h.open(); h.write("임시");
    h.window.dispatchEvent(new h.window.Event("pagehide"));
    assert.equal(h.ui(), null);
    assert.equal(h.window.localStorage.length, 0);
    assert.equal(h.window.sessionStorage.length, 0);
  } finally { h.close(); }
});

test("physical Control+Shift+J works; Command chord and ordinary reviewer keys pass through", () => {
  const h = setup();
  try {
    h.action("collapse");
    assert.equal(h.key("J", { code:"KeyJ", shiftKey:true, metaKey:true }).defaultPrevented, false);
    assert.equal(h.isOpen(), false);
    assert.equal(h.key("J", { code:"KeyJ", shiftKey:true, ctrlKey:true }).defaultPrevented, true);
    assert.equal(h.document.activeElement, h.input());
    h.key("Escape");
    let native = 0;
    h.document.addEventListener("keydown", () => native++);
    h.key(" ");
    assert.equal(native, 1);
    assert.equal(h.isOpen(), true);
  } finally { h.close(); }
});

test("editing keys do not reach the reviewer and retain default text editing", () => {
  const h = setup();
  try {
    h.open();
    let native = 0;
    h.document.addEventListener("keydown", () => native++);
    for (const key of [" ", "Enter", "1", "2", "3", "4", "e", "m", "r", "u", "ArrowUp", "Backspace"]) {
      assert.equal(h.key(key).defaultPrevented, false);
    }
    assert.equal(native, 0);
  } finally { h.close(); }
});

test("Escape first belongs to Korean IME composition, then only blurs the pad", () => {
  const h = setup();
  try {
    h.open(); h.write("한");
    let native = 0;
    h.document.addEventListener("keydown", () => native++);
    h.input().dispatchEvent(new h.window.CompositionEvent("compositionstart"));
    assert.equal(h.key("Escape", { isComposing:true }).defaultPrevented, false);
    assert.equal(h.document.activeElement, h.input());
    assert.equal(native, 0);
    h.input().dispatchEvent(new h.window.CompositionEvent("compositionend", { data:"한" }));
    assert.equal(h.key("Escape").defaultPrevented, true);
    assert.notEqual(h.document.activeElement, h.input());
    assert.equal(h.input().value, "한");
    assert.equal(h.isOpen(), true);
  } finally { h.close(); }
});

test("clear is immediate and mobile keyboard close only removes focus", () => {
  const h = setup({ mobile:true });
  try {
    h.open(); h.write("입력");
    assert.equal(h.ui().querySelector('[data-action="blur"]').hidden, false);
    h.action("blur");
    assert.equal(h.input().value, "입력");
    assert.equal(h.isOpen(), true);
    assert.notEqual(h.document.activeElement, h.input());
    h.action("clear");
    assert.equal(h.input().value, "");
    assert.equal(h.document.activeElement, h.input());
    assert.equal(h.ui().querySelector('[data-action="clear"]').disabled, true);
    assert.equal(h.ui().querySelector('[data-action="undo"]'), null);
  } finally { h.close(); }
});

test("pad interactions do not bubble to AnkiMobile tap handlers", () => {
  const h = setup({ mobile:true });
  try {
    h.open();
    let taps = 0;
    for (const name of ["click", "touchstart", "touchend", "pointerdown", "pointerup"]) {
      h.document.addEventListener(name, () => taps++);
      h.input().dispatchEvent(new h.window.Event(name, { bubbles:true, cancelable:true }));
    }
    assert.equal(taps, 0);
  } finally { h.close(); }
});

test("mobile documents preserve the native card parent and body-class updates keep the pad open", () => {
  const h = setup({ mobile:true, qa:false });
  try {
    h.open(); h.write("모바일");
    h.document.body.className = "iphone nightMode";
    h.window.eval(scratchpadScript);
    assert.equal(h.document.querySelectorAll(".anki-scratchpad-reader").length, 0);
    assert.equal(h.ui().parentElement, h.document.documentElement,
      "mobile pad stays outside the native transformed body");
    assert.equal(h.document.querySelector('[data-anki-scratchpad-card]').parentElement, h.document.body);
    assert.equal(h.document.querySelectorAll(".anki-scratchpad").length, 1);
    assert.equal(h.input().value, "모바일");
    assert.equal(h.isOpen(), true);
    assert.equal(h.ui().classList.contains("nightMode"), false);
  } finally { h.close(); }
});

test("replacing the mobile body with an unmanaged card removes the pad and preserves session preferences", async () => {
  const h=setup({mobile:true,qa:false});
  try {
    h.write("임시 답안");
    h.ui().querySelector('[role="separator"]').dispatchEvent(new h.window.KeyboardEvent("keydown",{key:"End",bubbles:true}));
    const replacement=h.document.createElement("body");
    replacement.innerHTML="<p>다른 유형</p>";
    h.document.documentElement.replaceChild(replacement,h.document.body);
    await h.flush();
    assert.equal(h.ui(),null);
    assert.equal(h.isOpen(),false);
    replacement.innerHTML=card("123456790");
    await h.flush();
    assert.equal(h.ui().parentElement,h.document.documentElement);
    assert.equal(h.input().value,"");
    assert.equal(h.isOpen(),true);
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"),"65");
  } finally {h.close();}
});

test("an open front keeps text/state on the answer, blurs input and remains editable", async () => {
  const h = setup();
  try {
    h.open(); h.write("PC를 반복 구간 주소로");
    await h.render("123456789", true);
    assert.equal(h.isOpen(), true);
    assert.equal(h.input().value, "PC를 반복 구간 주소로");
    assert.notEqual(h.document.activeElement, h.input());
    assert.equal(h.input().readOnly, false);
    h.input().focus(); h.write("뒷면에서 보완한 답");
    assert.equal(h.input().value, "뒷면에서 보완한 답");
  } finally { h.close(); }
});

test("the manually chosen closed state survives next cards and unmanaged cards", async () => {
  const h = setup();
  try {
    h.action("collapse");
    await h.render("123456790");
    assert.equal(h.isOpen(), false);
    h.document.getElementById("qa").innerHTML = '<p>다른 유형</p><span data-anki-cid="123456791"></span>';
    await h.flush();
    assert.equal(h.ui(), null);
    await h.render("123456792");
    assert.equal(h.isOpen(), false);
  } finally { h.close(); }
});

test("desktop viewport resize uses the visible space and preserves session size preference", () => {
  const h = setup();
  try {
    const view = new h.window.EventTarget();
    Object.assign(view, { width:390, height:360, offsetLeft:0, offsetTop:80 });
    Object.defineProperty(h.window, "visualViewport", { value:view, configurable:true });
    // Mounted after the platform supplies VisualViewport.
    h.window.dispatchEvent(new h.window.Event("pagehide"));
    h.window.AnkiScratchpadV1.mount();
    h.open();
    assert.equal(h.ui().style.height, "120px");
    assert.equal(h.ui().style.top, "");
    assert.equal(h.document.documentElement.style.getPropertyValue("--sp-view-top"), "80px");
    assert.equal(h.document.documentElement.style.getPropertyValue("--sp-view-height"), "440px");
    assert.equal(h.ui().querySelector('[role="separator"]').getAttribute("aria-valuenow"), "33");
  } finally { h.close(); }
});

test("mobile open/close, focus, answer and next-card transitions do not write native scroll positions", async () => {
  for (const qa of [false, true]) {
    const h = harness(qa ? `<div id="qa">${card()}</div>` : card(), {mobile:true,preload:false});
    try {
      const calls=[];
      for (const name of ["scrollTo","scrollBy"]) h.window[name]=(...args)=>calls.push([name,...args]);
      for (const name of ["scrollTo","scrollBy","scrollIntoView"]) h.window.Element.prototype[name]=(...args)=>calls.push([name,...args]);
      Object.defineProperty(h.window.Element.prototype,"scrollTop",{configurable:true,get:()=>150,set:value=>calls.push(["scrollTop",value])});
      h.window.eval(scratchpadScript);
      const input=h.document.querySelector("textarea");
      input.focus();input.value="한글\n회상";input.dispatchEvent(new h.window.Event("input",{bubbles:true}));
      h.document.querySelector('[data-action="blur"]').click();
      h.document.querySelector('[data-action="collapse"]').click();
      const options=[];const focus=input.focus.bind(input);
      input.focus=(...args)=>{options.push(args);focus(...args);};
      h.document.querySelector('.anki-scratchpad__launch').click();
      assert.deepEqual(options,[[]],"mobile focus uses the platform's normal panning");
      (h.document.getElementById("qa")||h.document.body).innerHTML=card("123456789",true);
      h.window.eval(scratchpadScript);await h.flush();
      (h.document.getElementById("qa")||h.document.body).innerHTML=card("123456790");
      h.window.eval(scratchpadScript);await h.flush();
      assert.deepEqual(calls,[],"scratchpad never sets document/reader scrolling on mobile");
    } finally {h.close();}
  }
});

test("mobile typing, focus and visual viewport panning do not rewrite layout geometry", async () => {
  const h=setup({mobile:true,qa:false});
  try {
    const style=h.document.documentElement.style;
    const initial=style.cssText;
    let writes=0;const set=style.setProperty.bind(style);
    style.setProperty=(...args)=>{writes++;set(...args);};
    const view=new h.window.EventTarget();
    Object.assign(view,{width:300,height:360,offsetLeft:30,offsetTop:80});
    Object.defineProperty(h.window,"visualViewport",{value:view,configurable:true});
    h.input().focus();h.write("첫 줄\n둘째 줄");h.action("blur");
    view.dispatchEvent(new h.window.Event("resize"));view.dispatchEvent(new h.window.Event("scroll"));
    await new Promise(resolve=>h.window.setTimeout(resolve,25));
    assert.equal(writes,0,"no geometry writes during keyboard focus/typing/panning");
    assert.equal(style.cssText,initial);
    assert.equal(h.document.querySelector('.anki-scratchpad-reader'),null);
  } finally {h.close();}
});

test("mobile resizing uses the same document coordinates as the fixed panel during keyboard panning", () => {
  const h=setup({mobile:true,qa:false});
  try {
    Object.defineProperty(h.window,"innerHeight",{value:844,configurable:true});
    Object.defineProperty(h.window,"visualViewport",{value:{height:360,width:300,offsetTop:80,offsetLeft:30},configurable:true});
    const handle=h.ui().querySelector('[role="separator"]');
    // The same panel may be panned above the keyboard; zero movement must
    // retain its ratio regardless of the touch's absolute client coordinate.
    for (const [type,props] of [["pointerdown",{pointerId:1,button:0,clientY:79}],["pointermove",{pointerId:1,clientY:79}]]) {
      const event=new h.window.Event(type,{bubbles:true,cancelable:true});
      for (const [key,value] of Object.entries(props)) Object.defineProperty(event,key,{value});
      handle.dispatchEvent(event);
    }
    assert.equal(handle.getAttribute("aria-valuenow"),"33");
    const move=new h.window.Event("pointermove",{bubbles:true,cancelable:true});
    Object.defineProperties(move,{pointerId:{value:1},clientY:{value:79-84.4}});
    handle.dispatchEvent(move);
    assert.equal(handle.getAttribute("aria-valuenow"),"43");
    assert.ok(Math.abs(parseFloat(h.ui().style.height)-365.7333333333333)<0.1);
  } finally {h.close();}
});
