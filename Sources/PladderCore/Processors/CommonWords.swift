import Foundation

/// The built-in lexicon `CustomWordCorrector` checks a single word against
/// before it rewrites it: a short list of the most common words of English,
/// German and Spanish, the languages the app dictates in.
///
/// Short on purpose. A word here is taken as what the speaker said and is
/// never fuzzily turned into one of the user's terms, so the list holds the
/// everyday words a term could sound like ("cloud", "shift", "rest") and
/// leaves out rarer ones a mis-hearing tends to produce ("clawed" for
/// "Claude"), which the corrector still has to repair. A full dictionary
/// would stop those repairs too, which is also why this is not AppKit's
/// spell checker; `PladderCore` may not import it anyway.
///
/// Only what a fuzzy match can reach is listed: lowercase ASCII letters, four
/// or more of them. Shorter keys only ever match exactly, and a word with an
/// umlaut or an accent never reaches the corrector's fuzzy path at all.
/// Contractions are spelled as the corrector keys them, without the
/// apostrophe ("dont").
enum CommonWords {
    static func contains(_ word: String) -> Bool {
        all.contains(word)
    }

    /// Builds the set, if it is not built yet. `CustomWordCorrector` calls
    /// this from `init`, which runs when settings change, so the first
    /// dictation that needs the lexicon does not pay for building it.
    static func prepare() {
        _ = all
    }

    /// Split on bytes rather than characters: the lists are ASCII, and
    /// grapheme breaking would make building the set several times slower.
    static let all: Set<String> = {
        var words = Set<String>(minimumCapacity: 2_048)
        for list in [english, german, spanish] {
            for word in list.utf8.split(separator: UInt8(ascii: " ")) {
                words.insert(String(decoding: word, as: UTF8.self))
            }
        }
        return words
    }()

    private static let english = """
        able about above accept access account across action active actual actually address \
        after afternoon again against agree ahead allow almost alone along already also \
        although always among amount animal another answer anyone anything anyway anywhere \
        apart apply area arent argue around arrive article aside asked attack attention \
        available avoid away baby back background balance ball band bank base basic basis \
        bear beat beautiful became because become been before began begin behind being \
        believe below best better between beyond bill bird birth black blood blue board \
        boat body book books both bottom brain branch bread break bring broke brother \
        brought brown budget build building built business busy button cake call called \
        calls came camera campaign cannot cant card care career carry case cases catch \
        cause cell center central century certain certainly chair challenge chance change \
        changes channel chapter character charge cheap check child children choice choose \
        church city claim class clean clear clearly click client climb clock close closed \
        cloud clouds club coach coat code coffee cold collect college color come comes \
        coming comment common company compare complete computer concern condition consider \
        contact contain content context continue control cook cool copy corner correct \
        cost could couldnt count country couple course court cover create credit crime \
        cross crowd culture current customer daily damage dark data date daughter dead \
        deal dear death debate decade decide decision deep defense degree deliver demand \
        department depend describe design desk despite detail determine develop device \
        didnt died difference different difficult dinner direction directly director \
        discover discuss disease doctor does doesnt doing dollar done dont door double down \
        draw dream dress drink drive driver drop during duty each early earn earth easily \
        east easy economic economy edge education effect effort eight either else email \
        employee empty energy enjoy enough enter entire environment error especially even \
        evening event ever every everybody everyone everything evidence exactly example \
        exist expect experience expert explain face fact factor fail fair fall family famous \
        fast father fear feature feel feeling feet field fight figure file files fill film \
        final finally financial find fine finger finish fire firm first fish five fixed \
        flat floor flow focus folder follow food foot force foreign forget form former \
        forward four free fresh friend friends from front fruit full fund funny future game \
        garden gave general generation gets getting girl give given glad glass goal goes \
        going gold gone good government great green ground group grow growth guess guest \
        hair half hall hand handle hang happen happy hard hasnt have havent head health hear \
        heard heart heat heavy held hello help here heres herself high hill himself history \
        hold hole home hope horse hospital host hotel hour hours house however huge human \
        hundred husband idea ideas identify image imagine impact important improve include \
        including increase indeed indicate industry information inside instead interest \
        interesting into isnt issue issues item items itself just keep kept kill kind king \
        kitchen knew know knowledge known lady land language large last late later laugh \
        lawyer lead leader learn least leave left legal less lets letter level life lift \
        light like likely limit line lines link list listen little live local lock long look \
        looking lose loss lost loud love lower luck lunch machine made mail main maintain \
        major make makes making manage manager many market marriage match matter maybe meal \
        mean meaning measure media medical meet meeting member memory mention menu message \
        method middle might mile military milk million mind mine minute minutes miss \
        mission mistake model modern moment money month months more morning most mother \
        mouth move movement movie much music must myself name names nation national natural \
        nature near nearly necessary neck need needs network never news next nice night none \
        noon north nose note notes nothing notice number numbers occur offer office officer \
        official often okay once only onto open operation option order other others ought \
        outside over owner pack page pages pain paint pair paper parent park part particular \
        partner party pass past paste path patient pattern peace people perform perhaps \
        period person personal phone photo physical pick picture piece place plan plane \
        plans plant play player please plus point police policy political pool poor popular \
        population position positive possible post power practice prepare present president \
        press pressure pretty prevent price print private probably problem problems process \
        produce product production professor program project property protect prove provide \
        public pull purpose push quality question questions quick quickly quiet quite race \
        radio rain raise range rate rather reach read ready real reality realize really \
        reason receive recent recently record reduce reflect region relate release remain \
        remember remove reply report represent require research resource respond response \
        rest result return reveal review rich ride right ring rise risk river road rock role \
        roll room root rule rules safe said sale same save scene school science score screen \
        script search season seat second section security seek seem seems seen sell send \
        sense sent series serious serve server service session seven several shake shall \
        shape share sheet shift ship shoe shop short shot should shouldnt shoulder show side \
        sign signal significant similar simple simply since sing single sister site sitting \
        situation size skill skin sleep slow small smart smile snow social society soft \
        soldier some somebody someone something sometimes song soon sorry sort sound source \
        south space speak special specific speech speed spend sport spot spring staff stage \
        stand standard star start started state statement station stay step still stock \
        stop store story straight strategy street strong structure student study stuff style \
        subject success successful such suddenly suffer suggest summer support sure surface \
        sweet system table take taken takes talk task tasks taste teach teacher team tell \
        tend term terms test tests text than thank thanks that thats their them themselves \
        then theory there theres these they theyre thing things think third this those \
        though thought thousand threat three through throw thus ticket time times today \
        together told tomorrow tonight took total touch tough toward town track trade \
        traditional train training travel treat treatment tree trial trip trouble true \
        truth turn type under understand unit until update upon used user users uses usually \
        value various very victim video view visit voice vote wait walk wall want wants \
        warm wasnt watch water ways weak wear week weekend weeks weight well went were \
        werent west what whats whatever wheel when where whether which while white whole \
        whom whose wide wife will wind window wine wish with within without woman women \
        wonder wont wood word words work worked worker working works world worry worse \
        worth would wouldnt write writer written wrong yeah year years yellow yesterday \
        young your youre yourself
        """

    private static let german = """
        aber abend alle allem allen aller alles also andere anderen anders arbeit arbeiten \
        auch auto bald beide beim bereits besser beste besten bild bisschen bitte bleiben \
        brauche brauchen bringen dabei damit danach danke dann daran darauf darf darum dass \
        davon dazu denen denke denken denn deren deshalb dich dies diese diesem diesen dieser \
        dieses ding dinge doch dort drei dran drin eben egal eigene eigentlich eine einem \
        einen einer eines einfach einige einmal ende endlich erst erste ersten etwas euch \
        fast fehler fertig finde finden firma frage fragen frau frei freund ganz ganze geben \
        gegen gehen geht geld genau gerade gerne gestern gibt gleich glaube glauben grund \
        gruppe habe haben halb hallo halt hand hast hatte hatten haus heute hier hilfe \
        hinter hoch holen ihre ihrem ihren ihrer immer jahr jahre jahren jede jedem jeden \
        jeder jedes jetzt kann kannst kein keine keinen keiner kind kinder klar klein kleine \
        kommen kommt konnte kurz lang lange lassen leben leider leute lieber liegt links \
        mache machen macht mann mehr mein meine meinem meinen meiner mich mittag montag \
        morgen muss musst nach nacht name neben nehmen nein neue neuen nicht nichts noch \
        nochmal oben oder ohne problem projekt punkt recht rechts richtig rost sache sagen \
        sagt schon schnell sehen sehr sein seine seinem seinen seiner seit seite selbst sich \
        sicher sind sogar soll sollen sollte sonst stadt stehen steht stelle stellen tage \
        teil termin trotzdem unser unsere unten unter viel viele vielen vielleicht vier voll \
        wann warum warten weil weiter welche welcher welt wenig wenn werden wieder will wird \
        wirklich wissen woche wohl wollen wort wurde wurden zeit ziel zusammen zwei zwischen
        """

    private static let spanish = """
        abajo abrir ahora algo alguien alguna alguno algunos alto amigo amiga antes arriba \
        asunto aunque ayer ayuda ayudar bajo bastante bien buena bueno buenos buenas cada \
        calle cambiar cambio casa casi caso cerca cierto cinco ciudad claro cliente comer \
        como contigo contra correo cosa cosas creo creer cuando cuanto cuatro cuenta \
        cuidado debe deben decir dejar dentro desde dice dicho digo dinero donde durante \
        ella ellas ellos empezar empresa encima entonces entre equipo esas esos espera \
        esperar esta estaba estar estas este esto estos estoy falta favor fecha forma fuera \
        gente gracias gran grande gusta haber habla hablar hace hacer hacia hago hasta \
        hecho hola hombre hora horas idea igual junto lado largo leer lejos llamar llegar \
        lleva llevar luego lugar lunes madre mano martes mayor mejor menos mesa mientras \
        mira mirar misma mismo momento mucha muchas mucho muchos mujer mundo nada nadie \
        necesito noche nombre nosotros nuestra nuestro nueva nuevo nunca otra otras otro \
        otros padre pagar palabra para parece parte pasa pasar pedir pensar pero persona \
        poco poder podemos porque pregunta primer primera primero problema pronto proyecto \
        pueblo puede pueden puedo puerta pues punto quiere quiero realmente saber salir \
        segundo seguir seguro semana sentir siempre siento siete sigue sino sobre solo \
        somos tanto tarde tener tengo tiempo tiene tienen toda todas todo todos tomar \
        trabajar trabajo tres unas unos usar usted ustedes vamos veces venir verdad viene \
        vida vuelta
        """
}
