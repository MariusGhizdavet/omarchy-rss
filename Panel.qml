import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "I18n.js" as I18n

// Cititor RSS în bară: un singur număr — câte știri necitite sunt în sursele
// configurate — și un panou cu lista lor. Panoul are două vederi: știrile și
// administrarea surselor (adaugă / șterge), comutate din butonul cu rotița.
//
// Widget-ul nu vorbește el cu rețeaua — nici măcar pentru ilustrații:
// bin/rss-preia descarcă în paralel sursele *și* miniaturile, verifică fiecare
// adresă înainte de cerere și scrie un singur JSON în care ilustrația e deja un
// fișier local. Așa, o adresă scrisă de un flux ostil nu poate deveni o cerere
// pornită din sesiunea utilizatorului. Starea trăiește în două fișiere —
// ~/.config/omarchy/rss/surse.json (sursele, editabil și de mână) și
// ~/.local/state/omarchy/rss.json (articolele deja citite).
//
// Niciun text vizibil nu e scris aici: totul vine din I18n.js, pe cheie, în
// limba dată de setarea `language` („Auto" = limba sistemului).
Panel {
  id: root
  moduleName: "mghizdavet.rss"
  ipcTarget: "rss"
  // manageIpc: false ca panoul să dețină el singurul IpcHandler pe care ținta
  // îl permite — avem nevoie de el pentru metodele de mai jos, care fac
  // widget-ul scriptabil (`omarchy-shell rss adauga <url>`).
  manageIpc: false

  // Cheile de setări au fost trecute în engleză la deschiderea plugin-ului
  // către catalog; numele românești de dinainte rămân acceptate, ca un
  // shell.json scris pe vechea versiune să nu-și piardă configurația.
  function setare(cheieNoua, cheieVeche, implicit) {
    var valoare = setting(cheieNoua, undefined)
    return valoare === undefined ? setting(cheieVeche, implicit) : valoare
  }

  // Codul limbii în care vorbește widget-ul. I18n.limba() acceptă și numele
  // afișat („Română", ce scrie selectul din setări), și codul („ro", ce scrie
  // omul care editează fișierul), și rezolvă „Auto" în locale-ul sistemului.
  readonly property string limba: I18n.limba(setare("language", "limba", "Auto"))
  // Ce e ales în selector, nu ce s-a rezolvat: cu „Auto" pastila aprinsă
  // trebuie să fie „Auto", nu limba pe care a nimerit-o sistemul.
  readonly property string limbaSetata: I18n.codLimba(setare("language", "limba", "Auto"))
  readonly property var limbiDisponibile: I18n.limbi()

  // Cadența ține de sursa de curent: în priză merită știri proaspete la câteva
  // minute, pe baterie fiecare preluare e o trezire de radio și trei descărcări
  // care nu se justifică la fel de des.
  readonly property int intervalPeReteaSec: Math.max(60, Math.min(7200, setare("refreshIntervalSec", "intervalPeReteaSec", 120)))
  readonly property int intervalPeBaterieSec: Math.max(60, Math.min(7200, setare("refreshIntervalOnBatterySec", "intervalPeBaterieSec", 600)))
  // UPower.onBattery e false și când nu există baterie deloc, ceea ce e
  // răspunsul corect pentru un desktop: stă permanent în priză.
  readonly property bool peRetea: !UPower.onBattery
  readonly property int intervalActualizareSec: peRetea ? intervalPeReteaSec : intervalPeBaterieSec
  readonly property int maximPerSursa: Math.max(5, Math.min(100, setare("maxItemsPerFeed", "maximPerSursa", 25)))
  readonly property int limitaAfisate: Math.max(10, Math.min(200, setare("maxItemsShown", "limitaAfisate", 40)))
  readonly property int timeoutSec: Math.max(3, Math.min(60, setting("timeoutSec", 12)))
  readonly property bool arataNumarul: setare("showCount", "arataNumarul", true) === true
  readonly property bool arataImagini: setare("showThumbnails", "arataImagini", true) === true
  readonly property bool doarNecitite: setare("unreadOnly", "doarNecitite", false) === true
  readonly property bool citesteLaDeschidere: setare("markAllReadOnClose", "citesteLaDeschidere", false) === true

  readonly property string acasa: Quickshell.env("HOME")
  // Sursele sunt configurație (le-ai scris tu, le vrei într-un backup de
  // ~/.config); articolele citite sunt stare regenerabilă și stau lângă
  // celelalte fișiere de stare ale shell-ului.
  readonly property string dosarSurse: acasa + "/.config/omarchy/rss"
  readonly property string caleSurse: dosarSurse + "/surse.json"
  readonly property string dosarStare: acasa + "/.local/state/omarchy"
  readonly property string caleCitite: dosarStare + "/rss.json"
  readonly property string caleScript: String(Qt.resolvedUrl("bin/rss-preia")).replace(/^file:\/\//, "")

  // Prima rulare: fișierul cu surse nu există încă, deci widget-ul nu ar avea
  // ce arăta — panoul s-ar deschide direct pe formularul de adăugare și ar cere
  // o adresă înainte să fi arătat la ce e bun. O sursă implicită de știri
  // internaționale rezolvă asta: la prima deschidere există deja un flux.
  //
  // Se scrie o singură dată, pe lipsa fișierului. Din clipa în care fișierul
  // există, o listă goală rămâne goală: cine își șterge toate sursele nu vrea
  // să i le repunem noi la următoarea pornire.
  readonly property var sursaImplicita: ({
    id: "bbc-world",
    nume: "BBC News",
    url: "https://feeds.bbci.co.uk/news/world/rss.xml"
  })

  // Cât timp ținem minte că un articol a fost citit. Peste asta a dispărut
  // demult din flux, deci intrarea nu mai poate marca nimic.
  readonly property int zileDePastrat: 90
  readonly property int limitaCitite: 5000

  property var raport: Model.raportGol()
  property var surse: []
  property var citite: ({})
  property bool sePreia: false
  property bool surseIncarcate: false
  property bool cititeIncarcate: false
  property bool vedereSurse: false
  // Cheia de traducere a ultimei încercări eșuate de adăugare, nu propoziția:
  // aceeași greșeală ajunge și în panou (în limba aleasă) și la ieșirea IPC
  // (în engleză, fiindcă acolo citește un script).
  property string eroareAdaugare: ""
  // Reper de timp pentru „acum 20 min”: ceasul îl împinge înainte, ca vârstele
  // afișate să nu înghețe cât timp panoul stă deschis.
  property date acum: new Date()

  readonly property color culoareText: bar ? bar.foreground : Color.foreground
  readonly property color culoareUrgent: bar ? bar.urgent : Color.urgent
  readonly property string fontulBarei: bar ? bar.fontFamily : Style.font.family

  readonly property int necitite: Model.numaraNecitite(raport.stiri, citite)
  readonly property bool arePreluareEsuata: String(raport.eroare || "") !== ""
  // Sursele care nu au răspuns nu fac widget-ul „urgent” — o singură știre
  // necitită da; altfel numărul din bară ar sta aprins degeaba.
  readonly property bool areNecitite: !arePreluareEsuata && necitite > 0

  // Aceeași propoziție apare în tooltipul din bară și în capul panoului, deci
  // se compune o dată.
  readonly property string rezumatul: I18n.rezumat(root.limba, root.raport, root.necitite,
                                                   root.surse.length, Model.surseEsuate(root.raport))

  readonly property string pictograma: "󰑫"

  // Lista efectiv desenată: filtrată de „doar necitite” și tăiată la limita
  // configurată, ca un flux generos să nu umple ecranul.
  readonly property var stiriAfisate: {
    var lista = []
    for (var i = 0; i < raport.stiri.length && lista.length < limitaAfisate; i++) {
      if (doarNecitite && citite[raport.stiri[i].id]) {
        continue
      }
      lista.push(raport.stiri[i])
    }
    return lista
  }

  // ------------------------------------------------------------- navigare

  // "stiri" | "surse" | "adauga" — care listă răspunde la j/k.
  property string sectiuneFocus: "stiri"
  property int indexSelectat: -1
  property bool cursorActiv: false

  function mutaCursorul(delta) {
    var lista = vedereSurse ? surse : stiriAfisate
    if (lista.length === 0) {
      return
    }

    root.cursorActiv = true
    root.sectiuneFocus = vedereSurse ? "surse" : "stiri"
    var urmator = root.indexSelectat + delta
    root.indexSelectat = Math.max(0, Math.min(lista.length - 1, urmator < 0 ? 0 : urmator))
  }

  function activeazaCursorul() {
    if (vedereSurse || root.indexSelectat < 0 || root.indexSelectat >= stiriAfisate.length) {
      return
    }
    root.deschide(stiriAfisate[root.indexSelectat])
  }

  function stergeSelectia() {
    if (vedereSurse) {
      if (root.indexSelectat >= 0 && root.indexSelectat < surse.length) {
        root.stergeSursa(surse[root.indexSelectat].id)
      }
      return
    }

    if (root.indexSelectat >= 0 && root.indexSelectat < stiriAfisate.length) {
      root.comutaCitit(stiriAfisate[root.indexSelectat].id)
    }
  }

  function tastaScurta(text) {
    if (text === "r") {
      root.actualizeaza()
    } else if (text === "a") {
      root.marcheazaToate()
    } else if (text === "s") {
      root.comutaVederea()
    } else if (text === "g") {
      root.duLaPrimaStire()
    } else if (text === "L") {
      // „L", nu „l": PanelKeyCatcher folosește deja litera mică pentru mutarea
      // vim-style la dreapta și consumă evenimentul, deci minuscula nu ajunge
      // niciodată până aici.
      root.cicleazaLimba()
    } else if (text === "n" && root.vedereSurse) {
      // Tab e deja luat de comutarea între panourile barei, deci câmpul de
      // adăugare are nevoie de o tastă a lui ca să fie accesibil fără mouse.
      campUrl.forceActiveFocus()
    }
  }

  // Înapoi la capul listei. Mută și cursorul pe prima știre, nu doar derularea:
  // altfel următorul j ar relua din locul unde stătea cursorul, undeva jos.
  // positionViewAtBeginning e chemat explicit fiindcă, dacă indexul era deja 0
  // iar derularea s-a făcut din roată, currentIndex nu se schimbă și nimic nu
  // ar readuce vederea sus.
  function duLaPrimaStire() {
    if (root.vedereSurse || root.stiriAfisate.length === 0) {
      return
    }

    root.cursorActiv = true
    root.sectiuneFocus = "stiri"
    root.indexSelectat = 0
    listaStiri.positionViewAtBeginning()
  }

  function comutaVederea() {
    root.vedereSurse = !root.vedereSurse
    root.eroareAdaugare = ""
    root.indexSelectat = -1
    root.cursorActiv = false
    root.sectiuneFocus = root.vedereSurse ? "surse" : "stiri"
  }

  // ------------------------------------------------------------------ limba

  // Setarea stă în shell.json, iar shell.json e al shell-ului: `setBarWidget`
  // e calea lui oficială de a schimba o setare de widget, și singura care
  // anunță și widget-ul viu. Se scrie numele întreg („Português (BR)"), nu
  // codul, ca fișierul să rămână citibil și să se potrivească cu opțiunile
  // declarate în manifest.
  function seteazaLimba(cod) {
    if (cod === root.limbaSetata) {
      return
    }
    Util.execArgv(["omarchy-shell", "shell", "setBarWidget", root.moduleName,
                   "language", JSON.stringify(I18n.numeLimba(cod)), "{}"])
  }

  // Tasta `L` trece la limba următoare, ca selectorul să fie folosibil și fără
  // mouse; după ultima se întoarce la „Auto".
  function cicleazaLimba() {
    var lista = root.limbiDisponibile
    for (var i = 0; i < lista.length; i++) {
      if (lista[i].cod === root.limbaSetata) {
        root.seteazaLimba(lista[(i + 1) % lista.length].cod)
        return
      }
    }
    root.seteazaLimba(lista.length > 0 ? lista[0].cod : "auto")
  }

  // ------------------------------------------------------------ preluarea

  function actualizeaza() {
    if (proces.running || !root.surseIncarcate) {
      return
    }

    root.sePreia = true
    proces.command = ["python3", root.caleScript, root.caleSurse,
                      String(root.maximPerSursa), String(root.timeoutSec),
                      root.arataImagini ? "1" : "0"]
    proces.running = true
  }

  function deschide(stire) {
    // A doua verificare a schemei, după cea din script: aici se naște o linie de
    // comandă, iar singurul lucru care are voie să ajungă în ea e o adresă web.
    var link = stire ? Model.linkWeb(stire.link) : ""
    if (link === "") {
      return
    }

    Util.execArgv(["omarchy-launch-browser", link])
    root.marcheazaCitit(stire.id)
  }

  // ------------------------------------------------------------- citirile

  function marcheazaCitit(id) {
    if (!id || root.citite[id]) {
      return
    }

    // Hărțile din QML nu notifică la mutație pe loc; scrie o copie nouă, ca
    // numărul din bară și opacitatea rândurilor să se recalculeze.
    var copie = Object.assign({}, root.citite)
    copie[id] = Math.floor(Date.now() / 1000)
    root.citite = copie
    root.programeazaSalvareaCititelor()
  }

  function comutaCitit(id) {
    if (!id) {
      return
    }

    var copie = Object.assign({}, root.citite)
    if (copie[id]) {
      delete copie[id]
    } else {
      copie[id] = Math.floor(Date.now() / 1000)
    }
    root.citite = copie
    root.programeazaSalvareaCititelor()
  }

  function marcheazaToate() {
    if (root.raport.stiri.length === 0) {
      return
    }

    var copie = Object.assign({}, root.citite)
    var moment = Math.floor(Date.now() / 1000)
    var schimbat = false

    // Marchează tot ce s-a preluat, nu doar ce se vede: filtrul „doar
    // necitite” și limita de afișare nu trebuie să lase în urmă știri
    // invizibile care reapar necitite la următoarea deschidere.
    for (var i = 0; i < root.raport.stiri.length; i++) {
      var id = root.raport.stiri[i].id
      if (!copie[id]) {
        copie[id] = moment
        schimbat = true
      }
    }

    if (schimbat) {
      root.citite = copie
      root.programeazaSalvareaCititelor()
    }
  }

  // ---------------------------------------------------------------- surse

  function adaugaSursa(urlBrut) {
    var url = Model.normalizeazaUrl(urlBrut)

    if (url === "") {
      root.eroareAdaugare = "errEmptyUrl"
      return false
    }

    if (Model.areUrl(root.surse, url)) {
      root.eroareAdaugare = "errDuplicate"
      return false
    }

    var lista = root.surse.slice()
    lista.push({ id: Model.idPentruUrl(url, lista), nume: "", url: url })
    root.surse = lista
    root.eroareAdaugare = ""
    root.salveazaSursele()
    // Numele îl aflăm din flux la prima preluare; până atunci rândul arată
    // gazda.
    root.actualizeaza()
    return true
  }

  function stergeSursa(id) {
    var lista = []
    for (var i = 0; i < root.surse.length; i++) {
      if (root.surse[i].id !== id) {
        lista.push(root.surse[i])
      }
    }

    if (lista.length === root.surse.length) {
      return
    }

    root.surse = lista
    root.indexSelectat = Math.min(root.indexSelectat, lista.length - 1)
    root.salveazaSursele()

    // Scoate imediat din raport știrile sursei șterse, ca numărul din bară să
    // scadă acum, nu la următorul tick.
    var raportNou = Model.raportGol()
    raportNou.actualizatLa = root.raport.actualizatLa
    raportNou.eroare = root.raport.eroare
    for (var s = 0; s < root.raport.surse.length; s++) {
      if (root.raport.surse[s].id !== id) {
        raportNou.surse.push(root.raport.surse[s])
      }
    }
    for (var a = 0; a < root.raport.stiri.length; a++) {
      if (root.raport.stiri[a].sursaId !== id) {
        raportNou.stiri.push(root.raport.stiri[a])
      }
    }
    root.raport = raportNou
  }

  // Prima preluare reușită aduce titlul fluxului; îl scriem în surse.json ca
  // lista de surse să arate „Digi24”, nu „digi24.ro”, și offline.
  function adoptaNumeleDescoperite() {
    var lista = root.surse.slice()
    var schimbat = false

    for (var i = 0; i < lista.length; i++) {
      if (lista[i].nume !== "") {
        continue
      }
      var stare = Model.stareSursa(lista[i], root.raport)
      if (stare && stare.numeDescoperit) {
        lista[i] = { id: lista[i].id, nume: stare.numeDescoperit, url: lista[i].url }
        schimbat = true
      }
    }

    if (schimbat) {
      root.surse = lista
      root.salveazaSursele()
    }
  }

  // ----------------------------------------------------------- persistență

  Process {
    id: creeazaDosare
    command: ["mkdir", "-p", root.dosarSurse, root.dosarStare]
    running: false
  }

  Process {
    id: proces
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.raport = Model.parseazaRaport(text)
        root.acum = new Date()
        root.sePreia = false
        root.adoptaNumeleDescoperite()
      }
    }
    onExited: root.sePreia = false
  }

  FileView {
    id: fisierSurse
    path: root.caleSurse
    // Fișierul e gândit să poată fi editat și de mână; când se schimbă pe disc
    // reîncărcăm lista fără să repornim shell-ul.
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.incarcaSursele(text())
    onLoadFailed: root.seamanaSursaImplicita()
    onFileChanged: reload()
  }

  FileView {
    id: fisierCitite
    path: root.caleCitite
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.incarcaCititele(text())
    // Un alt display al shell-ului (laptopul vs. monitorul extern) scrie același
    // fișier rss.json când marchează articole citite; preluăm variația ca să
    // afișăm același număr de necitite pe toate ecranele.
    onFileChanged: fisierCitite.reload()
    onLoadFailed: root.incarcaCititele("")
  }

  function incarcaSursele(brut) {
    var lista = Model.parseazaSurse(brut)
    var nou = Model.serializeazaSurse(lista)

    // Sări peste reîncărcarea provocată de propria noastră scriere: altfel
    // fiecare salvare ar reasigna `surse` și ar dărâma selecția din panou.
    if (root.surseIncarcate && nou === Model.serializeazaSurse(root.surse)) {
      return
    }

    root.surse = lista
    var primaData = !root.surseIncarcate
    root.surseIncarcate = true
    if (primaData) {
      root.actualizeaza()
    }
  }

  // Lipsa fișierului cu surse e semnalul de primă rulare — nu o eroare.
  function seamanaSursaImplicita() {
    if (root.surseIncarcate) {
      return
    }

    root.surse = [root.sursaImplicita]
    root.surseIncarcate = true
    fisierSurse.setText(Model.serializeazaSurse(root.surse))
    root.actualizeaza()
  }

  // Reîncarcă articolele citite de pe disc. Rulează la pornire și, prin
  // onFileChanged pe fisierCitite, de fiecare dată când un alt display al
  // shell-ului (laptopul, monitorul extern) scrie rss.json — astfel numărul
  // de necitite e sincronizat pe toate ecranele.
  function incarcaCititele(brut) {
    root.citite = Model.curataCitite(Model.parseazaCitite(brut), root.zileDePastrat, root.limitaCitite)
    root.cititeIncarcate = true
  }

  function salveazaSursele() {
    if (!root.surseIncarcate) {
      return
    }
    fisierSurse.setText(Model.serializeazaSurse(root.surse))
  }

  function programeazaSalvareaCititelor() {
    if (!root.cititeIncarcate) {
      return
    }
    salvareCitite.restart()
  }

  // „Marchează toate” atinge sute de intrări deodată; un mic răgaz strânge
  // rafala într-o singură scriere.
  Timer {
    id: salvareCitite
    interval: 250
    repeat: false
    onTriggered: fisierCitite.setText(
      Model.serializeazaCitite(Model.curataCitite(root.citite, root.zileDePastrat, root.limitaCitite)))
  }

  Component.onCompleted: {
    creeazaDosare.running = true
    // După ce mkdir a apucat un tick, citește fișierele existente.
    Qt.callLater(function () {
      fisierSurse.reload()
      fisierCitite.reload()
    })
  }

  Timer {
    // Schimbarea intervalului repornește cronometrul, deci trecerea între
    // cadențe se aplică de la următorul tick, nu de la finalul celui în curs.
    interval: root.intervalActualizareSec * 1000
    running: true
    repeat: true
    onTriggered: root.actualizeaza()
  }

  // Ai pus laptopul în priză: cel mai probabil tocmai te-ai așezat la el, deci
  // nu are rost să aștepți primul tick al cadenței rapide.
  onPeReteaChanged: if (peRetea) root.actualizeaza()

  // Miniaturile se aduc la preluare, nu la afișare, deci aprinderea lor cere o
  // preluare nouă; altfel casetele ar rămâne goale până la următorul tick.
  onArataImaginiChanged: if (arataImagini) root.actualizeaza()

  // Cât timp panoul e deschis, vârstele afișate se împrospătează singure.
  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.acum = new Date()
  }

  onOpenedChanged: {
    if (opened) {
      root.acum = new Date()
      root.vedereSurse = root.surse.length === 0
      root.indexSelectat = -1
      root.cursorActiv = false
      root.eroareAdaugare = ""
      root.actualizeaza()
    } else if (root.citesteLaDeschidere) {
      // La închidere, nu la deschidere: altfel numărul ar cădea la zero
      // înainte să apuci să vezi ce era nou.
      root.marcheazaToate()
    }
  }

  // ------------------------------------------------------------------- IPC

  IpcHandler {
    target: "rss"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function refresh(): string {
      root.actualizeaza()
      return "ok"
    }

    // Aceeași acțiune ca butonul cu căsuța, ca să poată fi legată de o tastă
    // din Hyprland fără să deschizi întâi panoul cu mouse-ul.
    function top(): string {
      root.duLaPrimaStire()
      return root.stiriAfisate.length > 0 ? "ok" : "no items"
    }

    function markAllRead(): string {
      root.marcheazaToate()
      return String(root.necitite)
    }

    function unread(): string {
      return String(root.necitite)
    }

    function status(): string {
      // Ieșirea IPC e pentru scripturi, deci rămâne în engleză oricare ar fi
      // limba interfeței: cine o parsează n-ar trebui să depindă de o setare.
      return "unread: " + String(root.necitite)
        + "\nitems: " + String(root.raport.stiri.length)
        + "\nfeeds: " + String(root.surse.length)
        + "\nupdated: " + (I18n.oraScurta(root.raport.actualizatLa) || "never")
        + "\npower: " + (root.peRetea ? "mains" : "battery")
        + "\ninterval: " + String(Math.round(root.intervalActualizareSec / 60)) + " min"
        + (root.raport.eroare ? "\nerror: " + I18n.textEroare(root.raport.eroare, "en") : "")
    }

    // Limba se schimbă și din afară, ca restul widget-ului. Getter și setter
    // separate fiindcă IpcHandler cere argumentele declarate: o metodă cu un
    // parametru nu poate fi chemată fără el.
    function language(): string {
      return I18n.numeLimba(root.limbaSetata)
    }

    // Merg numele întreg („Português (BR)"), codul („pt-BR") și „auto", exact
    // ca valorile acceptate în shell.json.
    function setLanguage(value: string): string {
      var cerut = String(value || "").trim()
      var cod = I18n.codLimba(cerut)
      // codLimba() cade pe „auto" pentru tot ce nu recunoaște, deci un nume
      // scris greșit ar trece limba pe automat în loc să se plângă.
      if (cod === "auto" && !I18n.esteAuto(cerut)) {
        var nume = []
        var lista = root.limbiDisponibile
        for (var i = 0; i < lista.length; i++) {
          nume.push(lista[i].nume)
        }
        return "unknown language: " + cerut + "\nknown: " + nume.join(", ")
      }

      root.seteazaLimba(cod)
      return "ok"
    }

    function cycleLanguage(): string {
      root.cicleazaLimba()
      return "ok"
    }

    function addFeed(url: string): string {
      if (!root.surseIncarcate) return "feeds not loaded yet"
      if (root.adaugaSursa(url)) return "ok"
      return root.eroareAdaugare ? I18n.t("en", root.eroareAdaugare) : "could not add the feed"
    }

    function removeFeed(id: string): string {
      var inainte = root.surse.length
      root.stergeSursa(String(id))
      return root.surse.length < inainte ? "ok" : "no feed with id " + id
    }

    function listFeeds(): string {
      var randuri = []
      for (var i = 0; i < root.surse.length; i++) {
        var stare = Model.stareSursa(root.surse[i], root.raport)
        randuri.push(root.surse[i].id + "\t" + Model.numeSursa(root.surse[i], root.raport)
          + "\t" + root.surse[i].url
          + "\t" + I18n.stareaSursei("en", stare))
      }
      return randuri.join("\n")
    }
  }

  // ------------------------------------------------------- widget-ul din bară

  implicitWidth: buton.implicitWidth
  implicitHeight: buton.implicitHeight

  WidgetButton {
    id: buton
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    // Numărul stă lângă pictogramă doar pe bară orizontală: pe verticală nu
    // încape text, deci rămâne pictograma singură.
    // Aer în jurul pilulei. Rândul de module al barei are spacing 0, deci tot
    // spațiul dintre widget-uri vine din marginea lor internă: cele 6px de
    // aici lăsau pilulele cu text lipite una de alta. 10px de fiecare parte
    // le desprinde, la fel în rss, things, erori-intranet și omatop.
    fixedWidth: vertical ? -1 : continut.implicitWidth + Style.space(20)
    fixedHeight: vertical ? continut.implicitHeight + Style.space(8) : -1
    active: root.areNecitite || root.arePreluareEsuata
    tooltipText: root.arePreluareEsuata
      ? I18n.t(root.limba, "tooltipError", { detail: I18n.textEroare(root.raport.eroare, root.limba) })
      : root.rezumatul
    onPressed: function (codButon) {
      // Click dreapta reîncarcă imediat, mijlociu marchează tot ca citit.
      if (codButon === Qt.RightButton) {
        root.actualizeaza()
      } else if (codButon === Qt.MiddleButton) {
        root.marcheazaToate()
      } else {
        root.toggle()
      }
    }

    Row {
      id: continut
      anchors.centerIn: parent
      // Style.spacing.labelGap („label-gap”, 4px) e tokenul comun al shell-ului
      // pentru o pictogramă lipită de eticheta ei — același pe care îl folosesc
      // celelalte pilule din bară. Strâns intenționat: pictograma și numărul
      // sunt un singur lucru („atâtea necitite”), nu doi vecini din bară.
      spacing: Style.spacing.labelGap

      // Pânza păstrează ÎNĂLȚIMEA standard a pictogramelor din bară
      // (BarIconButton), ca glifa să stea pe aceeași linie ca vecinii ei — o
      // cutie mai mică ar ridica-o. Lățimea, însă, e cea a cernelii: o pânză
      // pătrată lăsa un joc lateral diferit pentru fiecare glifă, așa că
      // spațiul până la număr ieșea 8-9px aici și 4px în altă parte, deși
      // toate declarau același labelGap. OpticalGlyph centrează cerneala pe
      // mijlocul pânzei, deci o pânză strânsă pe cerneală o lasă exact acolo.
      Item {
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: Math.ceil(glif.tightWidth)
        implicitHeight: Style.bar.iconCanvas

        OpticalGlyph {
          id: glif
          anchors.fill: parent
          text: root.pictograma
          // Peste `bar.iconFont` (13), nu la el. Tokenul e o mărime de font,
          // iar cerneala pe care o dă diferă mult de la glifă la glifă: la
          // 13px antena 󰑫 desena 8x8px pe bară, în timp ce vecinii ei din
          // secțiunea dreaptă ieșeau 10x12 (logoul things), 11x11 (󰻠,
          // procesorul) sau 12x12 (󰃤, buba erorilor). Deși declara exact
          // același token ca ei, pilula se citea mai mică decât toate. La
          // 17px cerneala ajunge la 11x11, adică fix pe procesor, și stă în
          // aceeași bandă verticală. Aceeași corecție — o glifă ridicată
          // peste `iconFont` pentru că tokenul măsoară fontul, nu desenul —
          // o face și omatop pentru glifele lui de metrici.
          fontSize: Style.bar.iconFont + Style.space(4)
          fontFamily: buton.fontFamily
          color: buton.foreground
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.arataNumarul && !buton.vertical
        text: I18n.etichetaBara(root.raport, root.necitite)
        color: buton.foreground
        font.family: buton.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }

  // ------------------------------------------------------------------ panoul

  KeyboardPanel {
    id: panou
    anchorItem: buton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: prinzatorTaste
    contentWidth: panou.fittedContentWidth(Style.space(560))
    contentHeight: panou.fittedContentHeight(coloana.implicitHeight)

    PanelKeyCatcher {
      id: prinzatorTaste
      anchors.fill: parent
      // Cât timp scrii o adresă, tastele sunt ale câmpului: altfel „j” ar sări
      // în listă în loc să ajungă în text.
      blocked: campUrl.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.mutaCursorul(dy) }
      onActivateRequested: root.activeazaCursorul()
      onDeleteRequested: root.stergeSelectia()
      onTextKey: function (text) { root.tastaScurta(text) }

      // PanelKeyCatcher nu are semnal pentru Home (tastele fără text cad prin
      // el), iar `g` singur nu e evident pentru cine caută tasta obișnuită.
      // Contextul implicit al lui Shortcut e fereastra, deci nu fură Home de
      // la alte panouri.
      Shortcut {
        sequences: ["Home"]
        enabled: root.opened && !root.vedereSurse && !campUrl.activeFocus
        onActivated: root.duLaPrimaStire()
      }

      Column {
        id: coloana
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Cap: titlu, rezumat, acțiuni ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(titluColoana.implicitHeight, actiuni.implicitHeight)

          Column {
            id: titluColoana
            anchors.left: parent.left
            anchors.right: actiuni.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelSectionHeader {
              text: I18n.t(root.limba, root.vedereSurse ? "headerFeeds" : "headerNews")
              foreground: root.culoareText
              fontFamily: root.fontulBarei
            }

            Text {
              width: parent.width
              text: root.rezumatul
              color: root.culoareText
              opacity: root.areNecitite || root.arePreluareEsuata ? 1 : 0.7
              font.family: root.fontulBarei
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Row {
            id: actiuni
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            ButonAntet {
              // Vizibil doar peste lista de știri: vederea de surse nu derulează.
              visible: !root.vedereSurse
              iconText: "󰋜"
              tooltipText: I18n.t(root.limba, "tipTop")
              enabled: root.stiriAfisate.length > 0
                && (!listaStiri.atYBeginning || root.indexSelectat > 0)
              onClicked: root.duLaPrimaStire()
            }

            ButonAntet {
              iconText: "󰄬"
              tooltipText: I18n.t(root.limba, "tipMarkAll")
              enabled: root.necitite > 0
              onClicked: root.marcheazaToate()
            }

            ButonAntet {
              iconText: root.vedereSurse ? "󰅁" : "󰒓"
              tooltipText: I18n.t(root.limba, root.vedereSurse ? "tipBackToNews" : "tipManageFeeds")
              // Vederea de surse e o stare, nu o acțiune de o clipă: pastila
              // rămâne aprinsă cât ești în ea, ca pastila scalării active.
              active: root.vedereSurse
              onClicked: root.comutaVederea()
            }

            ButonAntet {
              iconText: "󰑐"
              tooltipText: I18n.t(root.limba, "tipRefresh")
              // Button știe să rotească singur pictograma cât ține o operație.
              iconSpinning: root.sePreia
              enabled: !root.sePreia
              onClicked: root.actualizeaza()
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.culoareText
        }

        // ---------- Motivul eșecului global ----------
        Text {
          width: parent.width
          visible: root.arePreluareEsuata
          text: I18n.textEroare(root.raport.eroare, root.limba)
          color: root.culoareUrgent
          font.family: root.fontulBarei
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ---------- Vederea „știri” ----------
        Text {
          width: parent.width
          visible: !root.vedereSurse && root.stiriAfisate.length === 0
          text: I18n.t(root.limba, root.surse.length === 0
            ? "emptyNoFeeds"
            : (root.doarNecitite && root.raport.stiri.length > 0
              ? "emptyAllRead"
              : "emptyNoItems"))
          color: root.culoareText
          opacity: 0.7
          font.family: root.fontulBarei
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Listă cu înălțime plafonată: un flux generos nu trebuie să împingă
        // panoul în afara ecranului. ListView (nu Repeater) ca să avem
        // positionViewAtIndex — asta ține rândul ales de j/k în vizor.
        ListView {
          id: listaStiri
          visible: !root.vedereSurse && root.stiriAfisate.length > 0
          width: parent.width
          height: visible ? Math.min(contentHeight, Style.space(620)) : 0
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.vedereSurse ? [] : root.stiriAfisate
          currentIndex: root.sectiuneFocus === "stiri" ? root.indexSelectat : -1
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          // Delegatul ListView nu leagă contextul în componentele declarate cu
          // `component`, deci ia proprietățile aici și le pasează explicit.
          delegate: Item {
            id: invelisStire
            required property var modelData
            required property int index
            width: ListView.view.width
            implicitHeight: rand.implicitHeight

            RandStire {
              id: rand
              width: invelisStire.width
              stire: invelisStire.modelData
              index: invelisStire.index
            }
          }
        }

        // ---------- Vederea „surse” ----------
        Column {
          width: parent.width
          visible: root.vedereSurse
          spacing: Style.space(2)

          Repeater {
            model: root.vedereSurse ? root.surse : []

            // Ca la lista de știri: învelișul ia proprietățile din contextul
            // delegatului și le pasează explicit componentei inline.
            delegate: Item {
              id: invelisSursa
              required property var modelData
              required property int index
              width: parent.width
              implicitHeight: randSursa.implicitHeight

              RandSursa {
                id: randSursa
                width: invelisSursa.width
                sursa: invelisSursa.modelData
                pozitie: invelisSursa.index
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.vedereSurse && root.surse.length === 0
          text: I18n.t(root.limba, "emptyFeedList")
          color: root.culoareText
          opacity: 0.7
          font.family: root.fontulBarei
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ---------- Formularul de adăugare ----------
        Item {
          width: parent.width
          visible: root.vedereSurse
          implicitHeight: campUrl.implicitHeight

          TextField {
            id: campUrl
            anchors.left: parent.left
            anchors.right: butonAdauga.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: I18n.t(root.limba, "urlPlaceholder")
            foreground: root.culoareText
            enabled: !root.sePreia

            onAccepted: if (root.adaugaSursa(text)) { text = "" }
            onTextChanged: if (root.eroareAdaugare !== "") root.eroareAdaugare = ""
            // Esc predă tastele înapoi listei fără să șteargă ce ai scris; un
            // al doilea Esc, prins acum de PanelKeyCatcher, închide panoul.
            Keys.onEscapePressed: prinzatorTaste.forceActiveFocus()
          }

          PanelActionButton {
            id: butonAdauga
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐕"
            tooltipText: I18n.t(root.limba, "tipAddFeed")
            foreground: root.culoareText
            fontFamily: root.fontulBarei
            enabled: campUrl.text.trim().length > 0 && !root.sePreia
            onClicked: if (root.adaugaSursa(campUrl.text)) { campUrl.text = "" }
          }
        }

        Text {
          width: parent.width
          visible: root.vedereSurse && root.eroareAdaugare !== ""
          text: I18n.t(root.limba, root.eroareAdaugare)
          color: root.culoareUrgent
          font.family: root.fontulBarei
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- Selectorul de limbă ----------
        //
        // Schema din manifest declară setarea, dar shell-ul nu desenează (încă)
        // niciun panou de setări pentru plugin-uri: fără selectorul de aici,
        // limba s-ar putea schimba doar editând shell.json de mână. Stă în
        // vederea de surse, care e deja vederea „rotiței".
        Column {
          width: parent.width
          visible: root.vedereSurse
          spacing: Style.space(6)

          PanelSeparator {
            width: parent.width
            foreground: root.culoareText
          }

          Text {
            text: I18n.t(root.limba, "languageLabel")
            color: root.culoareText
            opacity: 0.55
            font.family: root.fontulBarei
            font.pixelSize: Style.font.caption
          }

          // Flow, nu Row: unsprezece pastile nu încap pe un rând într-un panou
          // de 560px, iar o listă verticală ar împinge piciorul mult în jos.
          Flow {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.vedereSurse ? root.limbiDisponibile : []

              delegate: PastilaLimba {
                required property var modelData
                eticheta: modelData.scurt
                cod: modelData.cod
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.culoareText
        }

        // ---------- Picior ----------
        Text {
          width: parent.width
          text: root.sePreia
            ? I18n.t(root.limba, "footerLoading")
            : (root.vedereSurse
              ? I18n.t(root.limba, "footerFeeds")
              : I18n.piciorStiri(root.limba, root.raport.actualizatLa))
          color: root.culoareText
          opacity: 0.55
          font.family: root.fontulBarei
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Butoanele din antet. Aceeași rețetă cu pastilele de scalare din panoul
  // „Display" al Omarchy (ScalePill): componenta Button a kitului cu
  // `bordered: true`, deci bordura, umplerea la hover, focus, apăsare și starea
  // activă vin toate din jetoanele temei — nimic desenat pe cont propriu.
  component ButonAntet: Button {
    foreground: root.culoareText
    fontFamily: root.fontulBarei
    horizontalPadding: Style.spacing.md
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    // Pătrat. La un buton cu o singură pictogramă lățimea naturală (o glifă
    // plus padding) e sub înălțime (linia de text plus același padding), deci
    // egalarea lărgește cutia, nu strânge conținutul.
    implicitWidth: implicitHeight
    // Button nu estompează singur starea dezactivată, iar întunecarea pe care o
    // face PanelActionButton arată, pe o temă deschisă, mai apăsat în loc de
    // mai șters. Aici scădem opacitatea, ceea ce merge în ambele sensuri.
    opacity: enabled ? 1 : 0.35
  }

  // O pastilă de limbă. Ca ButonAntet, dar cu text: lățimea rămâne cea a
  // etichetei, altfel „English" ar fi strâns la lățimea unei pictograme.
  component PastilaLimba: Button {
    required property string eticheta
    required property string cod

    text: eticheta
    foreground: root.culoareText
    fontFamily: root.fontulBarei
    fontSize: Style.font.caption
    horizontalPadding: Style.spacing.md
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    // Limba aleasă rămâne aprinsă cât e aleasă — e o stare, nu o acțiune.
    active: root.limbaSetata === cod
    onClicked: root.seteazaLimba(cod)
  }

  // Un rând de știre: miniatura la stânga, titlul întreg și, sub el, sursa cu
  // vechimea. Necitită = titlu plin și un punct în margine; citită = totul mai
  // șters. Click stânga deschide în browser și marchează citit, click dreapta
  // doar comută citit/necitit.
  component RandStire: CursorSurface {
    id: rand
    required property var stire
    required property int index

    readonly property bool eCitita: !!root.citite[rand.stire.id]
    readonly property bool eSelectata: root.sectiuneFocus === "stiri" && root.indexSelectat === rand.index

    hasCursor: root.cursorActiv && eSelectata
    foreground: root.culoareText
    accent: Color.accent

    implicitHeight: continutRand.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: rand.stire.link ? Qt.PointingHandCursor : Qt.ArrowCursor

      // Mutăm cursorul aici la intrarea mouse-ului; ieșirea nu îl șterge, ca
      // j/k să continue de unde a stat ultima dată mouse-ul.
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActiv = true
        root.sectiuneFocus = "stiri"
        root.indexSelectat = rand.index
      }

      onClicked: function (mouse) {
        if (mouse.button === Qt.RightButton) {
          root.comutaCitit(rand.stire.id)
        } else {
          root.deschide(rand.stire)
        }
      }
    }

    Item {
      id: continutRand
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      // Miniatura poate fi mai înaltă decât un titlu de un rând; rândul crește
      // după cel mai înalt dintre cele două.
      implicitHeight: Math.max(textRand.implicitHeight, miniatura.visible ? miniatura.height : 0)

      // Punctul de „necitit”: singurul semn care nu depinde de contrast, deci
      // rămâne lizibil și pe temele în care „mai șters” abia se vede.
      Text {
        id: punct
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: Style.space(2)
        width: Style.space(12)
        text: rand.eCitita ? "" : "●"
        color: Color.accent
        font.family: root.fontulBarei
        font.pixelSize: Style.font.caption
      }

      // Ilustrația articolului, când fluxul o dă. E un fișier local, adus și
      // verificat de bin/rss-preia, deci `Image` nu deschide nicio conexiune;
      // sourceSize rămâne ca decodarea să nu țină în memorie un JPEG de 4000px
      // pentru o casetă de 72. Cât timp lipsește, rămâne o suprafață goală de
      // aceeași dimensiune, ca lista să nu tresară.
      Rectangle {
        id: miniatura
        visible: root.arataImagini && rand.stire.imagine !== ""
        anchors.left: punct.right
        anchors.top: parent.top
        width: visible ? Style.space(112) : 0
        height: visible ? Style.space(84) : 0
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.culoareText, Color.accent)
        clip: true
        opacity: rand.eCitita ? 0.55 : 1

        Image {
          anchors.fill: parent
          source: miniatura.visible ? Model.urlFisier(rand.stire.imagine) : ""
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: Math.round(parent.width * 2)
          visible: status === Image.Ready
        }
      }

      Column {
        id: textRand
        anchors.left: miniatura.visible ? miniatura.right : punct.right
        anchors.leftMargin: miniatura.visible ? Style.space(10) : 0
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(2)

        Text {
          width: parent.width
          // Titlul se vede întreg: fluxurile care scriu paragrafe în <title>
          // (Biziday) merită rândul lor înalt, nu trei puncte.
          text: rand.stire.titlu
          color: root.culoareText
          opacity: rand.eCitita ? 0.5 : 1
          font.family: root.fontulBarei
          font.pixelSize: Style.font.body
          font.bold: !rand.eCitita
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }

        Text {
          width: parent.width
          text: {
            var varsta = I18n.catTimpInUrma(root.limba, rand.stire.data, root.acum)
            return varsta === "" ? rand.stire.sursa : rand.stire.sursa + " · " + varsta
          }
          color: root.culoareText
          opacity: rand.eCitita ? 0.4 : 0.6
          font.family: root.fontulBarei
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Un rând de sursă: numele și adresa, plus starea ultimei preluări. Butonul
  // din dreapta o scoate din listă.
  component RandSursa: CursorSurface {
    id: randS
    required property var sursa
    required property int pozitie

    readonly property var stare: Model.stareSursa(randS.sursa, root.raport)
    readonly property bool eSelectata: root.sectiuneFocus === "surse" && root.indexSelectat === randS.pozitie
    readonly property string mesajStare: I18n.stareaSursei(root.limba, randS.stare)

    hasCursor: root.cursorActiv && eSelectata
    foreground: root.culoareText
    accent: Color.accent

    implicitHeight: continutSursa.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActiv = true
        root.sectiuneFocus = "surse"
        root.indexSelectat = randS.pozitie
      }
    }

    Item {
      id: continutSursa
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(textSursa.implicitHeight, butonSterge.height)

      PanelActionButton {
        id: butonSterge
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅙"
        tooltipText: I18n.t(root.limba, "tipRemoveFeed")
        foreground: root.culoareText
        hoverColor: root.culoareUrgent
        fontFamily: root.fontulBarei
        onClicked: root.stergeSursa(randS.sursa.id)
      }

      Column {
        id: textSursa
        anchors.left: parent.left
        anchors.right: butonSterge.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: Model.numeSursa(randS.sursa, root.raport)
          color: root.culoareText
          font.family: root.fontulBarei
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: randS.sursa.url + " · " + randS.mesajStare
          color: randS.stare && randS.stare.eroare ? root.culoareUrgent : root.culoareText
          opacity: randS.stare && randS.stare.eroare ? 0.9 : 0.55
          font.family: root.fontulBarei
          font.pixelSize: Style.font.caption
          // Adresa contează la coadă („…/rss”), nu la cap.
          elide: Text.ElideLeft
        }
      }
    }
  }
}