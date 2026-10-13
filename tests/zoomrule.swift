// Confere a regra do zoom automático (FocuSee). Rodar: cd Sources && swiftc -swift-version 5 Model.swift Theme.swift ../tests/zoomrule.swift -o /tmp/zt && /tmp/zt
// Regra do FocuSee com os cliques do projeto Meet (sem filtro de área: amostras dentro da tela)
let s = (0..<300).map { Sample(t: Double($0) * 0.1, x: 0.5, y: 0.5) }
let ev = Events(samples: s, clicks: [14.891, 15.642, 25.411], pointScale: 2)
let z = Settings.autoZooms(ev, level: 2, typing: true)
print(z.map { ($0.a, $0.b) })
assert(z.count == 2 && abs(z[0].a - 14.571) < 1e-6 && abs(z[0].b - 16.908) < 1e-6 && abs(z[1].b - 26.677) < 1e-6)
// digitação: 6 teclas em 1 s viram um trecho; 2 teclas soltas não
let keys = (0..<6).map { KeyPress(t: 5 + Double($0) * 0.2, s: "a", combo: false) } + [KeyPress(t: 20, s: "b", combo: false), KeyPress(t: 20.3, s: "c", combo: false)]
let r = Settings.typingRanges(keys)
print(r); assert(r.count == 1 && r[0].0 == 5 && abs(r[0].1 - 6) < 1e-9)
print("ok")
