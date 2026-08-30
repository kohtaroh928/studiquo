import SwiftUI
import SwiftData
import Security
import UIKit
import UserNotifications

/// Any university that publishes an iCalendar feed from its LMS — Moodle,
/// Canvas, Sakai, manaba — can be connected. The feed is fetched over HTTPS
/// and parsed here; the institution is identified from the URL's domain
/// purely so imported items can be labelled, and an unrecognised domain
/// still syncs.
enum UniversityCalendar {
    static let externalSource = "university"

    private static let service = "com.yabuko.studiquo.university-calendar"
    /// Where the Waseda-only build stored its link, read once so anyone who
    /// already connected keeps their calendar after updating.
    private static let legacyService = "com.yabuko.studiquo.waseda-moodle"
    private static let account = "calendar-url"
    private static let storedNameKey = "universityCalendarName"

    /// Domain suffix → display name. Matching the university's own domain
    /// rather than the LMS host means a school's Moodle keeps working even
    /// when it lives on a subdomain this table has never seen.
    ///
    /// A school missing from the table is never blocked from connecting —
    /// its items are simply labelled with the feed's host instead of a
    /// name (see `displayName(forURL:)`).
    static let directory: [(domain: String, name: String)] = japaneseDirectory + internationalDirectory

    private static let japaneseDirectory: [(domain: String, name: String)] = [
        ("waseda.jp", "早稲田大学"),
        ("keio.jp", "慶應義塾大学"),
        ("u-tokyo.ac.jp", "東京大学"),
        ("kyoto-u.ac.jp", "京都大学"),
        ("osaka-u.ac.jp", "大阪大学"),
        ("tohoku.ac.jp", "東北大学"),
        ("nagoya-u.ac.jp", "名古屋大学"),
        ("kyushu-u.ac.jp", "九州大学"),
        ("hokudai.ac.jp", "北海道大学"),
        ("hit-u.ac.jp", "一橋大学"),
        ("isct.ac.jp", "東京科学大学"),
        ("titech.ac.jp", "東京科学大学"),
        ("tsukuba.ac.jp", "筑波大学"),
        ("kobe-u.ac.jp", "神戸大学"),
        ("hiroshima-u.ac.jp", "広島大学"),
        ("okayama-u.ac.jp", "岡山大学"),
        ("chiba-u.ac.jp", "千葉大学"),
        ("saitama-u.ac.jp", "埼玉大学"),
        ("ibaraki.ac.jp", "茨城大学"),
        ("gunma-u.ac.jp", "群馬大学"),
        ("utsunomiya-u.ac.jp", "宇都宮大学"),
        ("shinshu-u.ac.jp", "信州大学"),
        ("niigata-u.ac.jp", "新潟大学"),
        ("kanazawa-u.ac.jp", "金沢大学"),
        ("u-toyama.ac.jp", "富山大学"),
        ("u-fukui.ac.jp", "福井大学"),
        ("shizuoka.ac.jp", "静岡大学"),
        ("gifu-u.ac.jp", "岐阜大学"),
        ("mie-u.ac.jp", "三重大学"),
        ("yamanashi.ac.jp", "山梨大学"),
        ("wakayama-u.ac.jp", "和歌山大学"),
        ("tottori-u.ac.jp", "鳥取大学"),
        ("shimane-u.ac.jp", "島根大学"),
        ("yamaguchi-u.ac.jp", "山口大学"),
        ("tokushima-u.ac.jp", "徳島大学"),
        ("kagawa-u.ac.jp", "香川大学"),
        ("ehime-u.ac.jp", "愛媛大学"),
        ("kochi-u.ac.jp", "高知大学"),
        ("nagasaki-u.ac.jp", "長崎大学"),
        ("kumamoto-u.ac.jp", "熊本大学"),
        ("oita-u.ac.jp", "大分大学"),
        ("saga-u.ac.jp", "佐賀大学"),
        ("kagoshima-u.ac.jp", "鹿児島大学"),
        ("ryukyu.ac.jp", "琉球大学"),
        ("hirosaki-u.ac.jp", "弘前大学"),
        ("iwate-u.ac.jp", "岩手大学"),
        ("akita-u.ac.jp", "秋田大学"),
        ("yamagata-u.ac.jp", "山形大学"),
        ("tuat.ac.jp", "東京農工大学"),
        ("uec.ac.jp", "電気通信大学"),
        ("tufs.ac.jp", "東京外国語大学"),
        ("ocha.ac.jp", "お茶の水女子大学"),
        ("geidai.ac.jp", "東京藝術大学"),
        ("tmu.ac.jp", "東京都立大学"),
        ("naist.jp", "奈良先端科学技術大学院大学"),
        ("jaist.ac.jp", "北陸先端科学技術大学院大学"),
        ("meiji.ac.jp", "明治大学"),
        ("rikkyo.ac.jp", "立教大学"),
        ("hosei.ac.jp", "法政大学"),
        ("chuo-u.ac.jp", "中央大学"),
        ("sophia.ac.jp", "上智大学"),
        ("aoyama.ac.jp", "青山学院大学"),
        ("gakushuin.ac.jp", "学習院大学"),
        ("tus.ac.jp", "東京理科大学"),
        ("nihon-u.ac.jp", "日本大学"),
        ("toyo.ac.jp", "東洋大学"),
        ("komazawa-u.ac.jp", "駒澤大学"),
        ("senshu-u.ac.jp", "専修大学"),
        ("tokai.ac.jp", "東海大学"),
        ("teikyo-u.ac.jp", "帝京大学"),
        ("kokugakuin.ac.jp", "國學院大學"),
        ("seikei.ac.jp", "成蹊大学"),
        ("seijo.ac.jp", "成城大学"),
        ("musashi.ac.jp", "武蔵大学"),
        ("soka.ac.jp", "創価大学"),
        ("shibaura-it.ac.jp", "芝浦工業大学"),
        ("icu.ac.jp", "国際基督教大学"),
        ("tsuda.ac.jp", "津田塾大学"),
        ("jwu.ac.jp", "日本女子大学"),
        ("twcu.ac.jp", "東京女子大学"),
        ("ritsumei.ac.jp", "立命館大学"),
        ("apu.ac.jp", "立命館アジア太平洋大学"),
        ("doshisha.ac.jp", "同志社大学"),
        ("kansai-u.ac.jp", "関西大学"),
        ("kwansei.ac.jp", "関西学院大学"),
        ("kindai.ac.jp", "近畿大学"),
        ("ryukoku.ac.jp", "龍谷大学"),
        ("oit.ac.jp", "大阪工業大学"),
        ("nanzan-u.ac.jp", "南山大学"),
        ("meijo-u.ac.jp", "名城大学"),
        ("nodai.ac.jp", "東京農業大学"),
        ("kitasato-u.ac.jp", "北里大学"),
        ("juntendo.ac.jp", "順天堂大学"),
        ("fukuoka-u.ac.jp", "福岡大学"),
        ("seinan-gu.ac.jp", "西南学院大学"),
    ]

    /// Overseas schools, so an exchange student or an applicant abroad gets
    /// the same recognised-name treatment as a domestic one. Entries are
    /// ordered most-specific-first within a family (`ens.psl.eu` ahead of
    /// `psl.eu`), because `universityName(forURL:)` takes the first suffix
    /// match it finds.
    private static let internationalDirectory: [(domain: String, name: String)] = [
        // United States
        ("harvard.edu", "Harvard University"),
        ("mit.edu", "Massachusetts Institute of Technology"),
        ("stanford.edu", "Stanford University"),
        ("berkeley.edu", "UC Berkeley"),
        ("ucla.edu", "UCLA"),
        ("ucsd.edu", "UC San Diego"),
        ("ucdavis.edu", "UC Davis"),
        ("uci.edu", "UC Irvine"),
        ("ucsb.edu", "UC Santa Barbara"),
        ("yale.edu", "Yale University"),
        ("princeton.edu", "Princeton University"),
        ("columbia.edu", "Columbia University"),
        ("uchicago.edu", "University of Chicago"),
        ("cornell.edu", "Cornell University"),
        ("upenn.edu", "University of Pennsylvania"),
        ("caltech.edu", "California Institute of Technology"),
        ("jhu.edu", "Johns Hopkins University"),
        ("northwestern.edu", "Northwestern University"),
        ("duke.edu", "Duke University"),
        ("brown.edu", "Brown University"),
        ("dartmouth.edu", "Dartmouth College"),
        ("rice.edu", "Rice University"),
        ("vanderbilt.edu", "Vanderbilt University"),
        ("emory.edu", "Emory University"),
        ("georgetown.edu", "Georgetown University"),
        ("nd.edu", "University of Notre Dame"),
        ("cmu.edu", "Carnegie Mellon University"),
        ("gatech.edu", "Georgia Institute of Technology"),
        ("nyu.edu", "New York University"),
        ("bu.edu", "Boston University"),
        ("usc.edu", "University of Southern California"),
        ("umich.edu", "University of Michigan"),
        ("msu.edu", "Michigan State University"),
        ("utexas.edu", "University of Texas at Austin"),
        ("washington.edu", "University of Washington"),
        ("illinois.edu", "University of Illinois Urbana-Champaign"),
        ("wisc.edu", "University of Wisconsin–Madison"),
        ("umn.edu", "University of Minnesota"),
        ("purdue.edu", "Purdue University"),
        ("umd.edu", "University of Maryland"),
        ("psu.edu", "Penn State University"),
        ("osu.edu", "Ohio State University"),
        ("ufl.edu", "University of Florida"),
        ("unc.edu", "University of North Carolina at Chapel Hill"),
        ("virginia.edu", "University of Virginia"),
        ("rutgers.edu", "Rutgers University"),
        ("pitt.edu", "University of Pittsburgh"),
        ("colorado.edu", "University of Colorado Boulder"),
        ("arizona.edu", "University of Arizona"),
        ("asu.edu", "Arizona State University"),

        // United Kingdom and Ireland
        ("ox.ac.uk", "University of Oxford"),
        ("cam.ac.uk", "University of Cambridge"),
        ("imperial.ac.uk", "Imperial College London"),
        ("ucl.ac.uk", "University College London"),
        ("lse.ac.uk", "London School of Economics"),
        ("kcl.ac.uk", "King's College London"),
        ("qmul.ac.uk", "Queen Mary University of London"),
        ("ed.ac.uk", "University of Edinburgh"),
        ("gla.ac.uk", "University of Glasgow"),
        ("st-andrews.ac.uk", "University of St Andrews"),
        ("manchester.ac.uk", "University of Manchester"),
        ("bristol.ac.uk", "University of Bristol"),
        ("warwick.ac.uk", "University of Warwick"),
        ("leeds.ac.uk", "University of Leeds"),
        ("soton.ac.uk", "University of Southampton"),
        ("bham.ac.uk", "University of Birmingham"),
        ("sheffield.ac.uk", "University of Sheffield"),
        ("nottingham.ac.uk", "University of Nottingham"),
        ("durham.ac.uk", "Durham University"),
        ("york.ac.uk", "University of York"),
        ("lancaster.ac.uk", "Lancaster University"),
        ("exeter.ac.uk", "University of Exeter"),
        ("bath.ac.uk", "University of Bath"),
        ("tcd.ie", "Trinity College Dublin"),
        ("ucd.ie", "University College Dublin"),

        // Canada
        ("utoronto.ca", "University of Toronto"),
        ("mcgill.ca", "McGill University"),
        ("ubc.ca", "University of British Columbia"),
        ("ualberta.ca", "University of Alberta"),
        ("uwaterloo.ca", "University of Waterloo"),
        ("mcmaster.ca", "McMaster University"),
        ("queensu.ca", "Queen's University"),
        ("umontreal.ca", "Université de Montréal"),
        ("sfu.ca", "Simon Fraser University"),
        ("uottawa.ca", "University of Ottawa"),
        ("ucalgary.ca", "University of Calgary"),
        ("uwo.ca", "Western University"),

        // Australia and New Zealand
        ("unimelb.edu.au", "University of Melbourne"),
        ("sydney.edu.au", "University of Sydney"),
        ("anu.edu.au", "Australian National University"),
        ("unsw.edu.au", "UNSW Sydney"),
        ("uq.edu.au", "University of Queensland"),
        ("monash.edu", "Monash University"),
        ("adelaide.edu.au", "University of Adelaide"),
        ("uwa.edu.au", "University of Western Australia"),
        ("uts.edu.au", "University of Technology Sydney"),
        ("auckland.ac.nz", "University of Auckland"),
        ("otago.ac.nz", "University of Otago"),

        // Continental Europe
        ("ethz.ch", "ETH Zürich"),
        ("epfl.ch", "EPFL"),
        ("uzh.ch", "University of Zurich"),
        ("unige.ch", "University of Geneva"),
        ("unil.ch", "University of Lausanne"),
        ("tum.de", "Technical University of Munich"),
        ("lmu.de", "LMU Munich"),
        ("uni-heidelberg.de", "Heidelberg University"),
        ("hu-berlin.de", "Humboldt University of Berlin"),
        ("fu-berlin.de", "Freie Universität Berlin"),
        ("tu-berlin.de", "Technische Universität Berlin"),
        ("rwth-aachen.de", "RWTH Aachen University"),
        ("kit.edu", "Karlsruhe Institute of Technology"),
        ("uni-freiburg.de", "University of Freiburg"),
        ("uni-goettingen.de", "University of Göttingen"),
        ("uni-bonn.de", "University of Bonn"),
        ("uni-tuebingen.de", "University of Tübingen"),
        ("ens.psl.eu", "École Normale Supérieure"),
        ("psl.eu", "Université PSL"),
        ("sorbonne-universite.fr", "Sorbonne Université"),
        ("polytechnique.edu", "École Polytechnique"),
        ("universite-paris-saclay.fr", "Université Paris-Saclay"),
        ("sciencespo.fr", "Sciences Po"),
        ("tudelft.nl", "Delft University of Technology"),
        ("uva.nl", "University of Amsterdam"),
        ("vu.nl", "Vrije Universiteit Amsterdam"),
        ("leidenuniv.nl", "Leiden University"),
        ("uu.nl", "Utrecht University"),
        ("ru.nl", "Radboud University"),
        ("rug.nl", "University of Groningen"),
        ("wur.nl", "Wageningen University & Research"),
        ("tue.nl", "Eindhoven University of Technology"),
        ("kuleuven.be", "KU Leuven"),
        ("ugent.be", "Ghent University"),
        ("ulb.be", "Université libre de Bruxelles"),
        ("univie.ac.at", "University of Vienna"),
        ("tuwien.ac.at", "TU Wien"),
        ("ku.dk", "University of Copenhagen"),
        ("dtu.dk", "Technical University of Denmark"),
        ("uio.no", "University of Oslo"),
        ("ntnu.no", "NTNU"),
        ("kth.se", "KTH Royal Institute of Technology"),
        ("ki.se", "Karolinska Institutet"),
        ("uu.se", "Uppsala University"),
        ("lu.se", "Lund University"),
        ("chalmers.se", "Chalmers University of Technology"),
        ("helsinki.fi", "University of Helsinki"),
        ("aalto.fi", "Aalto University"),
        ("unibo.it", "University of Bologna"),
        ("polimi.it", "Politecnico di Milano"),
        ("uniroma1.it", "Sapienza University of Rome"),
        ("unipd.it", "University of Padua"),
        ("unimi.it", "University of Milan"),
        ("ucm.es", "Complutense University of Madrid"),
        ("uam.es", "Autonomous University of Madrid"),
        ("ub.edu", "University of Barcelona"),
        ("upf.edu", "Pompeu Fabra University"),
        ("ulisboa.pt", "University of Lisbon"),
        ("up.pt", "University of Porto"),
        ("uw.edu.pl", "University of Warsaw"),
        ("uj.edu.pl", "Jagiellonian University"),
        ("cuni.cz", "Charles University"),
        ("elte.hu", "Eötvös Loránd University"),

        // Asia and the Middle East
        ("nus.edu.sg", "National University of Singapore"),
        ("ntu.edu.sg", "Nanyang Technological University"),
        ("smu.edu.sg", "Singapore Management University"),
        ("hku.hk", "University of Hong Kong"),
        ("ust.hk", "HKUST"),
        ("cuhk.edu.hk", "Chinese University of Hong Kong"),
        ("cityu.edu.hk", "City University of Hong Kong"),
        ("polyu.edu.hk", "Hong Kong Polytechnic University"),
        ("tsinghua.edu.cn", "Tsinghua University"),
        ("pku.edu.cn", "Peking University"),
        ("fudan.edu.cn", "Fudan University"),
        ("sjtu.edu.cn", "Shanghai Jiao Tong University"),
        ("zju.edu.cn", "Zhejiang University"),
        ("ustc.edu.cn", "University of Science and Technology of China"),
        ("nju.edu.cn", "Nanjing University"),
        ("snu.ac.kr", "Seoul National University"),
        ("kaist.ac.kr", "KAIST"),
        ("yonsei.ac.kr", "Yonsei University"),
        ("korea.ac.kr", "Korea University"),
        ("postech.ac.kr", "POSTECH"),
        ("skku.edu", "Sungkyunkwan University"),
        ("ntu.edu.tw", "National Taiwan University"),
        ("nycu.edu.tw", "National Yang Ming Chiao Tung University"),
        ("iisc.ac.in", "Indian Institute of Science"),
        ("iitb.ac.in", "IIT Bombay"),
        ("iitd.ac.in", "IIT Delhi"),
        ("iitm.ac.in", "IIT Madras"),
        ("iitk.ac.in", "IIT Kanpur"),
        ("chula.ac.th", "Chulalongkorn University"),
        ("mahidol.ac.th", "Mahidol University"),
        ("ui.ac.id", "Universitas Indonesia"),
        ("um.edu.my", "University of Malaya"),
        ("upd.edu.ph", "University of the Philippines Diliman"),
        ("huji.ac.il", "Hebrew University of Jerusalem"),
        ("tau.ac.il", "Tel Aviv University"),
        ("technion.ac.il", "Technion"),
        ("boun.edu.tr", "Boğaziçi University"),
        ("ku.edu.tr", "Koç University"),
        ("kaust.edu.sa", "KAUST"),
        ("kfupm.edu.sa", "KFUPM"),

        // Latin America and Africa
        ("unam.mx", "UNAM"),
        ("tec.mx", "Tecnológico de Monterrey"),
        ("usp.br", "University of São Paulo"),
        ("unicamp.br", "Unicamp"),
        ("puc-rio.br", "PUC-Rio"),
        ("uchile.cl", "University of Chile"),
        ("uc.cl", "Pontificia Universidad Católica de Chile"),
        ("uba.ar", "University of Buenos Aires"),
        ("uct.ac.za", "University of Cape Town"),
        ("wits.ac.za", "University of the Witwatersrand"),
        ("up.ac.za", "University of Pretoria"),
    ]

    /// Best-effort label for the feed's owner. `nil` for a school that isn't
    /// in the table — syncing is unaffected, the items are just labelled
    /// with the host instead.
    static func universityName(forURL raw: String) -> String? {
        guard let host = URL(string: normalizedURLString(raw))?.host?.lowercased() else { return nil }
        return directory.first { host == $0.domain || host.hasSuffix("." + $0.domain) }?.name
    }

    /// What imported items are labelled with: the recognised university name,
    /// or the feed's host when the school isn't in the table.
    static func displayName(forURL raw: String) -> String {
        if let known = universityName(forURL: raw) { return known }
        return URL(string: normalizedURLString(raw))?.host ?? "大学"
    }

    static var storedName: String? {
        get { UserDefaults.standard.string(forKey: storedNameKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: storedNameKey) }
    }

    static func loadURL() -> String {
        if let value = keychainValue(service: service) { return value }
        // Carry over the link saved by the Waseda-only build.
        if let legacy = keychainValue(service: legacyService) {
            saveURL(legacy)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            return legacy
        }
        return ""
    }

    private static func keychainValue(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func saveURL(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removeURL() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    struct Event {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let notes: String
        let isAllDay: Bool
    }

    /// LMS subscription links are handed out as `webcal://`, which
    /// `URLSession` refuses to load — the scheme only tells the OS to open a
    /// calendar app. The address behind it is an ordinary HTTPS one.
    static func normalizedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["webcal://", "webcals://"] where value.lowercased().hasPrefix(scheme) {
            value = "https://" + value.dropFirst(scheme.count)
        }
        return value
    }

    static func fetch(from rawURL: String) async throws -> [Event] {
        guard let url = URL(string: normalizedURLString(rawURL)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.contains(".") == true else {
            throw SyncError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.downloadFailed
        }
        // Feeds are UTF-8 in practice; fall back to Latin-1 so a mis-declared
        // one still parses instead of silently importing nothing.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else {
            throw SyncError.notACalendar
        }
        return parse(text)
    }

    /// One `NAME;PARAM=value:content` line. The parameters matter: they carry
    /// `TZID`, which decides what wall-clock time a deadline actually lands
    /// on, and `VALUE=DATE`, which marks an all-day entry.
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    private static func parse(_ text: String) -> [Event] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }

        var result: [Event] = []
        var fields: [String: Property] = [:]
        var inEvent = false
        var alarmDepth = 0

        for line in lines {
            let marker = line.trimmingCharacters(in: .whitespaces).uppercased()
            if marker == "BEGIN:VEVENT" { inEvent = true; alarmDepth = 0; fields = [:]; continue }
            if marker == "END:VEVENT" {
                if let event = event(from: fields) { result.append(event) }
                inEvent = false
                continue
            }
            guard inEvent else { continue }
            // A VALARM carries its own TRIGGER/DESCRIPTION; folding those in
            // would overwrite the event's own description.
            if marker.hasPrefix("BEGIN:") && marker != "BEGIN:VEVENT" { alarmDepth += 1; continue }
            if marker.hasPrefix("END:") { alarmDepth = max(0, alarmDepth - 1); continue }
            guard alarmDepth == 0, let property = property(from: line) else { continue }
            fields[property.name] = property
        }
        return result
    }

    private static func property(from line: String) -> Property? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = head.split(separator: ";").map(String.init)
        guard let name = segments.first?.trimmingCharacters(in: .whitespaces).uppercased(),
              !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Property(name: name, parameters: parameters, value: value)
    }

    private static func event(from fields: [String: Property]) -> Event? {
        guard let title = fields["SUMMARY"]?.value, !title.isEmpty,
              let start = date(from: fields["DTSTART"]) else { return nil }

        let end: Date
        if let explicit = date(from: fields["DTEND"]) {
            // An all-day DTEND is exclusive: it names the morning *after*.
            end = start.isAllDay ? explicit.date.addingTimeInterval(-1) : explicit.date
        } else if let seconds = duration(from: fields["DURATION"]?.value) {
            end = start.date.addingTimeInterval(seconds)
        } else if start.isAllDay {
            end = start.date.addingTimeInterval(86_399)
        } else {
            end = start.date
        }

        let identifier = fields["UID"]?.value
            ?? "\(title)-\(start.date.timeIntervalSince1970)"
        return Event(
            id: identifier,
            title: unescape(title),
            startDate: start.date,
            endDate: max(end, start.date),
            notes: unescape(fields["DESCRIPTION"]?.value ?? ""),
            isAllDay: start.isAllDay
        )
    }

    /// The zone comes from the value itself: a trailing `Z` means UTC, and
    /// otherwise the property's own `TZID` decides. Reading `TZID` matters now
    /// that any university can connect — the previous code discarded every
    /// parameter and assumed Asia/Tokyo, which is wrong for a school (or a
    /// feed) on another clock. Each form is matched by exact length because
    /// `date(from:)` ignores trailing characters, so a loose pattern can
    /// quietly accept a value it only partly understood.
    private static func date(from property: Property?) -> (date: Date, isAllDay: Bool)? {
        guard let property else { return nil }
        let raw = property.value.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if raw.hasSuffix("Z"), raw.count == 16 {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            if let date = formatter.date(from: String(raw.dropLast())) { return (date, false) }
        }

        let zone = property.parameters["TZID"].flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "Asia/Tokyo")
            ?? .current
        formatter.timeZone = zone

        if raw.count == 15 {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            if let date = formatter.date(from: raw) { return (date, false) }
        }
        if raw.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            if let date = formatter.date(from: raw) { return (date, true) }
        }
        return nil
    }

    private static func duration(from value: String?) -> TimeInterval? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        let isNegative = text.hasPrefix("-")
        if isNegative || text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()

        var total: TimeInterval = 0
        var digits = ""
        var inTimeSection = false
        for character in text {
            if character == "T" { inTimeSection = true; continue }
            if character.isNumber { digits.append(character); continue }
            let amount = TimeInterval(digits) ?? 0
            digits = ""
            switch character {
            case "W": total += amount * 604_800
            case "D": total += amount * 86_400
            case "H": total += amount * 3_600
            case "M": total += inTimeSection ? amount * 60 : 0
            case "S": total += amount
            default: break
            }
        }
        return isNegative ? -total : total
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    enum SyncError: LocalizedError {
        case invalidURL, downloadFailed, notACalendar
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                L("カレンダーURLの形式が正しくありません。大学のLMSで発行したリンクを貼り付けてください。")
            case .downloadFailed:
                L("カレンダーを取得できませんでした。通信状況を確認し、URLを再発行してお試しください。")
            case .notACalendar:
                L("このURLからカレンダーを読み取れませんでした。エクスポート用のリンクか確認してください。")
            }
        }
    }

    private static let notificationIdentifierPrefix = "university-deadline-"

    static func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func scheduleDeadlineNotifications(for items: [Event], university: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.map(\.identifier).filter { $0.hasPrefix(notificationIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)

        let calendar = Calendar.current
        let now = Date.now
        for item in items where item.endDate > now {
            var fireDate = calendar.date(
                bySettingHour: 8, minute: 0, second: 0,
                of: calendar.startOfDay(for: item.startDate)
            ) ?? item.startDate
            if fireDate <= now {
                fireDate = now.addingTimeInterval(60)
            }

            let content = UNMutableNotificationContent()
            content.title = L("\(university)・今日締切の予定があります")
            content.body = item.isAllDay
                ? item.title
                : L("\(item.title)・\(item.endDate.formatted(date: .omitted, time: .shortened))まで")
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: notificationIdentifierPrefix + item.id,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    static func cancelAllDeadlineNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let obsolete = requests.map(\.identifier).filter { $0.hasPrefix(notificationIdentifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
        }
    }
}

/// Google Calendar, connected through the private iCal address Google issues
/// for a calendar (Settings → that calendar → "Integrate calendar" → "Secret
/// address in iCal format").
///
/// Deliberately not OAuth: the secret URL needs no Google Cloud project, no
/// consent screen, and no token refresh, and it reuses the iCal fetching and
/// parsing this app already does for university feeds. The trade-off is that
/// the link is read-only and has to be re-issued if the user resets it.
enum GoogleCalendar {
    static let externalSource = "google-calendar"

    private static let service = "com.yabuko.studiquo.google-calendar"
    private static let account = "calendar-url"

    static func loadURL() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func saveURL(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removeURL() { saveURL("") }
}

struct CalendarHomeView: View {
    /// Owned by `ContentView`, which builds the panel — the calendar just
    /// needs somewhere to anchor it, so the drop-down appears under this
    /// screen's own bell rather than the one on the notes home.
    @Binding var showsNotifications: Bool
    let notificationPanel: () -> AnyView
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @Query(sort: \StudyActivity.startedAt, order: .reverse) private var studyActivities: [StudyActivity]
    @State private var selectedDate = Date.now
    @State private var displayedMonth = Date.now
    @State private var showsNewEvent = false
    @State private var editingEvent: CalendarEvent?
    @State private var showsUniversityConnection = false
    @State private var universityCalendarURL = UniversityCalendar.loadURL()
    @State private var googleCalendarURL = GoogleCalendar.loadURL()
    @State private var googleStatus = ""
    @State private var isGoogleSyncing = false
    @State private var universityStatus = ""
    @State private var isUniversitySyncing = false
    @State private var cachedEventKindsByDay: [Date: Set<CalendarEventKind>] = [:]

    /// Includes anything running *through* the day, not just starting on it,
    /// so a multi-day entry stays visible for its whole span.
    private var selectedDayEvents: [CalendarEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return events.filter { $0.startDate < dayEnd && $0.endDate >= dayStart }
    }

    /// Which event kinds land on each day, so the calendar grid can mark a
    /// day without the cost of re-scanning every event per cell. A multi-day
    /// entry marks every day it spans, not just the one it starts on.
    private func makeEventKindsByDay() -> [Date: Set<CalendarEventKind>] {
        let calendar = Calendar.current
        var result: [Date: Set<CalendarEventKind>] = [:]
        for event in events {
            var cursor = calendar.startOfDay(for: event.startDate)
            let lastDay = calendar.startOfDay(for: event.endDate)
            var daysWalked = 0
            while cursor <= lastDay, daysWalked < 366 {
                result[cursor, default: []].insert(event.kind)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                daysWalked += 1
            }
        }
        return result
    }

    private var todayStudySeconds: TimeInterval {
        studyActivities.filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.duration }
    }

    private var currentStudyStreak: Int {
        let calendar = Calendar.current
        let studiedDays = Set(studyActivities.map { calendar.startOfDay(for: $0.startedAt) })
        var cursor = calendar.startOfDay(for: .now)
        if !studiedDays.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while studiedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        calendarPanel
                            .frame(maxWidth: .infinity)
                        Divider()
                        eventList
                            .frame(width: min(420, geometry.size.width * 0.38))
                    }
                } else {
                    VStack(spacing: 0) {
                        calendarPanel
                        Divider()
                        eventList
                    }
                }
            }
        }
        .navigationTitle("カレンダー")
        // Keeps the grid on the right month when selectedDate is moved from
        // outside this view — e.g. tapping a notification for a future date.
        .onChange(of: selectedDate) { _, newValue in
            if !Calendar.current.isDate(newValue, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = newValue
            }
        }
        .onAppear {
            refreshEventKindsByDay()
        }
        .onChange(of: events.count) { _, _ in
            refreshEventKindsByDay()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button { showsNotifications = true } label: {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("通知")
                    .popover(isPresented: $showsNotifications, arrowEdge: .top) {
                        notificationPanel()
                    }
                    Button { showsUniversityConnection = true } label: {
                        Image(systemName: universityCalendarURL.isEmpty && googleCalendarURL.isEmpty
                              ? "link.badge.plus" : "link.circle.fill")
                    }
                    .accessibilityLabel("カレンダー連携")
                    Button {
                        showsNewEvent = true
                    } label: {
                        Label("予定を追加", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showsNewEvent) {
            CalendarEventEditor(event: nil, initialDate: selectedDate)
        }
        .sheet(item: $editingEvent) { event in
            CalendarEventEditor(event: event, initialDate: event.startDate)
        }
        .sheet(isPresented: $showsUniversityConnection) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("カレンダーURL", text: $universityCalendarURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("今すぐ同期", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await syncUniversityCalendar() }
                        }
                        .disabled(isUniversitySyncing || universityCalendarURL.isEmpty)
                        if isUniversitySyncing { ProgressView() }
                        if !universityStatus.isEmpty {
                            Text(universityStatus).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("カレンダーURL")
                    } footer: {
                        Text("在学中の大学のLMS（Moodle・Canvas・Blackboardなど）で発行した購読用リンクを貼り付けてください。国内・海外どちらの大学にも対応しています。課題・小テスト・授業の期限を取り込みます。URLはこの端末の安全な領域に保存され、締切当日の朝8時に通知でお知らせします。")
                    }
                    if let detected = UniversityCalendar.universityName(forURL: universityCalendarURL) {
                        Section {
                            Label(detected, systemImage: "building.columns.fill")
                        } header: {
                            Text("認識された大学")
                        }
                    }
                    Section {
                        SecureField("Googleカレンダーの非公開iCal URL", text: $googleCalendarURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Googleカレンダーを同期", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await syncGoogleCalendar() }
                        }
                        .disabled(isGoogleSyncing || googleCalendarURL.isEmpty)
                        if isGoogleSyncing { ProgressView() }
                        if !googleStatus.isEmpty {
                            Text(googleStatus).foregroundStyle(.secondary)
                        }
                        if !GoogleCalendar.loadURL().isEmpty {
                            Button("Googleカレンダーの連携を解除", role: .destructive) {
                                GoogleCalendar.removeURL()
                                googleCalendarURL = ""
                                googleStatus = L("連携を解除しました。")
                            }
                        }
                    } header: {
                        Text("Googleカレンダー")
                    } footer: {
                        Text("Googleカレンダーを開き、左の「マイカレンダー」で対象カレンダーの︙→「設定と共有」→「カレンダーの統合」にある『iCal 形式の非公開 URL』をコピーして貼り付けてください。読み取り専用で取り込みます。URLを知る人は誰でも予定を見られるため、他人に共有しないでください。")
                    }

                    if !UniversityCalendar.loadURL().isEmpty {
                        Section {
                            Button("連携を解除", role: .destructive) {
                                UniversityCalendar.removeURL()
                                UniversityCalendar.storedName = nil
                                universityCalendarURL = ""
                                universityStatus = L("連携を解除しました。")
                                UniversityCalendar.cancelAllDeadlineNotifications()
                            }
                        }
                    }
                }
                .navigationTitle("カレンダー連携")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { showsUniversityConnection = false }
                    }
                }
            }
        }
    }

    @MainActor
    private func syncUniversityCalendar() async {
        isUniversitySyncing = true
        universityStatus = ""
        defer { isUniversitySyncing = false }
        do {
            let imported = try await UniversityCalendar.fetch(from: universityCalendarURL)
            let university = UniversityCalendar.displayName(forURL: universityCalendarURL)

            // Matches on the current key and on the one the Waseda-only build
            // wrote, so an existing calendar is updated rather than duplicated.
            var existing: [String: CalendarEvent] = [:]
            for event in events {
                guard event.externalSource == UniversityCalendar.externalSource
                        || event.externalSource == "waseda-moodle",
                      let id = event.externalID else { continue }
                existing[id] = event
            }

            let incomingIDs = Set(imported.map(\.id))
            for item in imported {
                let event = existing[item.id] ?? {
                    let created = CalendarEvent(title: item.title, startDate: item.startDate,
                                                endDate: item.endDate, kind: .other, notes: item.notes)
                    modelContext.insert(created)
                    return created
                }()
                event.title = item.title
                event.startDate = item.startDate
                event.endDate = item.endDate
                event.notes = item.notes
                event.externalID = item.id
                event.externalSource = UniversityCalendar.externalSource
                event.externalSourceName = university
            }
            for event in existing.values where !incomingIDs.contains(event.externalID ?? "") {
                EventReminderNotifications.cancel(for: event)
                modelContext.delete(event)
            }
            try modelContext.save()
            refreshEventKindsByDay()

            UniversityCalendar.saveURL(universityCalendarURL)
            UniversityCalendar.storedName = university
            await UniversityCalendar.requestNotificationPermission()
            await UniversityCalendar.scheduleDeadlineNotifications(for: imported, university: university)
            universityStatus = imported.isEmpty
                ? L("\(university)に接続しましたが、取り込める予定がありませんでした。")
                : L("\(university)の予定を\(imported.count)件同期しました。")
        } catch {
            universityStatus = error.localizedDescription
        }
    }

    /// Same import path as a university feed, tagged with its own source so
    /// the two never overwrite each other's events.
    private func syncGoogleCalendar() async {
        isGoogleSyncing = true
        googleStatus = ""
        defer { isGoogleSyncing = false }
        do {
            let imported = try await UniversityCalendar.fetch(from: googleCalendarURL)

            var existing: [String: CalendarEvent] = [:]
            for event in events {
                guard event.externalSource == GoogleCalendar.externalSource,
                      let id = event.externalID else { continue }
                existing[id] = event
            }

            let incomingIDs = Set(imported.map(\.id))
            for item in imported {
                let event = existing[item.id] ?? {
                    let created = CalendarEvent(title: item.title, startDate: item.startDate,
                                                endDate: item.endDate, kind: .other, notes: item.notes)
                    modelContext.insert(created)
                    return created
                }()
                event.title = item.title
                event.startDate = item.startDate
                event.endDate = item.endDate
                event.notes = item.notes
                event.externalID = item.id
                event.externalSource = GoogleCalendar.externalSource
                event.externalSourceName = L("Googleカレンダー")
            }
            // Anything that vanished upstream goes here too, so a deleted
            // Google event does not linger in the app forever.
            for event in existing.values where !incomingIDs.contains(event.externalID ?? "") {
                EventReminderNotifications.cancel(for: event)
                modelContext.delete(event)
            }
            try modelContext.save()
            refreshEventKindsByDay()

            GoogleCalendar.saveURL(googleCalendarURL)
            await UniversityCalendar.requestNotificationPermission()
            googleStatus = imported.isEmpty
                ? L("接続しましたが、取り込める予定がありませんでした。")
                : L("Googleカレンダーの予定を\(imported.count)件同期しました。")
        } catch {
            googleStatus = error.localizedDescription
        }
    }

    private func refreshEventKindsByDay() {
        cachedEventKindsByDay = makeEventKindsByDay()
    }

    private var calendarPanel: some View {
        ScrollView {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                learningMetric(
                    title: "今日の勉強時間",
                    value: formattedDuration(todayStudySeconds),
                    icon: "clock.fill",
                    color: .blue
                )
                learningMetric(
                    title: "連続学習日数",
                    value: "\(currentStudyStreak)日",
                    icon: "flame.fill",
                    color: .orange
                )
            }
            .padding(.horizontal)

            MonthCalendarGrid(
                selectedDate: $selectedDate,
                displayedMonth: $displayedMonth,
                eventKindsByDay: cachedEventKindsByDay,
                colorFor: color(for:)
            )
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .indigo.opacity(0.10), radius: 14, y: 5)
                .padding()

            HStack(spacing: 14) {
                eventLegend(.test)
                eventLegend(.classLesson)
                eventLegend(.other)
            }
            .padding(.bottom, 12)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.10), Color.cyan.opacity(0.07), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func learningMetric(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.bold()).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.18)))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        return minutes >= 60
            ? L("\(minutes / 60)時間\(minutes % 60)分")
            : L("\(minutes)分")
    }

    private func eventLegend(_ kind: CalendarEventKind) -> some View {
        Label(kind.title, systemImage: kind.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color(for: kind))
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.title3.bold())
                    Text("\(selectedDayEvents.count)件の予定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showsNewEvent = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding()

            if selectedDayEvents.isEmpty {
                ContentUnavailableView(
                    "予定はありません",
                    systemImage: "calendar.badge.plus",
                    description: Text("＋からテストや授業の予定を追加できます")
                )
            } else {
                List {
                    ForEach(selectedDayEvents) { event in
                        // Deliberately not a `Button`: inside a `List` on
                        // iPad, a row `Button` needs one tap to give the row
                        // focus and a second to actually fire — the platform
                        // focus system treats the two as separate steps. A
                        // plain tap gesture on the row's own content fires
                        // immediately, matching a single tap.
                        HStack(spacing: 12) {
                            Image(systemName: event.kind.icon)
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(color(for: event.kind), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.headline)
                                Text(event.startDate.formatted(date: .omitted, time: .shortened)
                                     + "〜"
                                     + event.endDate.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !event.notes.isEmpty {
                                    Text(event.notes).font(.caption).lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingEvent = event }
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                EventReminderNotifications.cancel(for: event)
                                modelContext.delete(event)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func color(for kind: CalendarEventKind) -> Color {
        switch kind {
        case .test: .red
        case .classLesson: .blue
        case .other: .orange
        }
    }
}

/// A month grid built from scratch rather than `DatePicker(.graphical)`,
/// which has no supported way to decorate individual days — there's no hook
/// to draw the "something is happening here" dot this view exists for.
private struct MonthCalendarGrid: View {
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    let eventKindsByDay: [Date: Set<CalendarEventKind>]
    let colorFor: (CalendarEventKind) -> Color

    private let calendar = Calendar.current
    /// Dot order matches the legend beneath the grid (test, class, other) so
    /// the same color always means the same thing.
    private let kindOrder: [CalendarEventKind] = [.test, .classLesson, .other]

    var body: some View {
        VStack(spacing: 14) {
            header
            weekdayHeader
            dayGrid
        }
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                .font(.headline)
            Spacer()
            Button { shiftMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
        }
        .foregroundStyle(.indigo)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 6) {
            ForEach(daysToDisplay, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inDisplayedMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let kinds = kindOrder.filter { (eventKindsByDay[calendar.startOfDay(for: day)] ?? []).contains($0) }

        return Button {
            selectedDate = day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(
                        isSelected ? .white : (inDisplayedMonth ? .primary : .secondary.opacity(0.4))
                    )
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(Color.indigo)
                        } else if isToday {
                            Circle().strokeBorder(Color.indigo, lineWidth: 1.5)
                        }
                    }

                HStack(spacing: 3) {
                    ForEach(kinds, id: \.self) { kind in
                        Circle().fill(colorFor(kind)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Always 42 cells (6 full weeks) so the grid's height doesn't jump
    /// between months with four weeks and months with six.
    private var daysToDisplay: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let gridStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start
        else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func shiftMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = next
    }
}

/// Per-event "coming up soon" reminders, distinct from
/// `UniversityCalendar`'s once-a-day deadline digest: each event gets its
/// own notification at a lead time the user picks when creating or editing
/// it, keyed by the event's own stable `id` so it can be rescheduled or
/// cancelled independently of every other event's reminder.
enum EventReminderNotifications {
    private static let identifierPrefix = "event-reminder-"

    static func schedule(for event: CalendarEvent) async {
        let identifier = identifierPrefix + event.id.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        // An absolute reminder date wins; events saved before the editor
        // switched to one fall back to their stored offset.
        let requested: Date?
        if let explicit = event.reminderDate {
            requested = explicit
        } else {
            let option = EventReminderOption(minutesBefore: event.reminderMinutesBefore)
            requested = option == .none
                ? nil
                : event.startDate.addingTimeInterval(-Double(option.rawValue) * 60)
        }
        guard let requested else { return }

        // Never fire at or after the event itself, even if the start time was
        // dragged earlier after the reminder was set.
        let fireDate = min(requested, event.startDate.addingTimeInterval(-60))
        guard fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = L("もうすぐ予定です")
        content.body = L("\(event.title)・\(event.startDate.formatted(date: .omitted, time: .shortened))")
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancel(for event: CalendarEvent) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifierPrefix + event.id.uuidString]
        )
    }
}

private struct CalendarEventEditor: View {
    let event: CalendarEvent?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var kind: CalendarEventKind
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String
    /// The moment the reminder fires, picked outright rather than chosen from
    /// a list of offsets. `nil` means no reminder.
    @State private var reminderDate: Date?
    @State private var remindersEnabled: Bool

    init(event: CalendarEvent?, initialDate: Date) {
        self.event = event
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        _title = State(initialValue: event?.title ?? "")
        _kind = State(initialValue: event?.kind ?? .classLesson)
        _startDate = State(initialValue: event?.startDate ?? defaultStart)
        _endDate = State(initialValue: event?.endDate ?? defaultStart.addingTimeInterval(3600))
        _notes = State(initialValue: event?.notes ?? "")

        let start = event?.startDate ?? defaultStart
        if let existing = event?.reminderDate {
            _reminderDate = State(initialValue: existing)
            _remindersEnabled = State(initialValue: true)
        } else {
            // Falls back to the offset the old picker stored, so an event
            // created before this screen changed keeps its reminder.
            let storedMinutes = event?.reminderMinutesBefore ?? 30
            let enabled = storedMinutes >= 0
            _remindersEnabled = State(initialValue: enabled)
            _reminderDate = State(
                initialValue: start.addingTimeInterval(-Double(enabled ? storedMinutes : 30) * 60)
            )
        }
    }

    /// The latest instant a reminder may fire: one minute before the event.
    /// A notification at or after the thing it is reminding you about is
    /// useless, so the picker is bounded rather than merely validated.
    private var latestReminderDate: Date {
        startDate.addingTimeInterval(-60)
    }

    private var effectiveReminderDate: Date {
        min(reminderDate ?? latestReminderDate, latestReminderDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("予定") {
                    TextField("タイトル", text: $title)
                    Picker("種類", selection: $kind) {
                        ForEach(CalendarEventKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.icon).tag(kind)
                        }
                    }
                }
                Section("日時") {
                    DatePicker("開始", selection: $startDate)
                    DatePicker("終了", selection: $endDate, in: startDate...)
                }
                Section {
                    Toggle("通知する", isOn: $remindersEnabled)
                    if remindersEnabled {
                        DatePicker(
                            "通知日時",
                            selection: Binding(
                                get: { effectiveReminderDate },
                                set: { reminderDate = min($0, latestReminderDate) }
                            ),
                            in: ...latestReminderDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )

                        Text(reminderSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("通知は予定の開始時刻より前にしか設定できません。開始時刻を早めると、通知日時も自動でその前に繰り上がります。")
                }
                Section("メモ") {
                    TextField("教室、範囲、持ち物など", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(event == nil ? L("予定を追加") : L("予定を編集"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Kept in step with `reminderDate` so anything still reading the old
    /// offset field (and the summary line below) stays correct.
    private var minutesBeforeStart: Int {
        max(1, Int(abs(startDate.timeIntervalSince(effectiveReminderDate)) / 60))
    }

    private var reminderSummary: String {
        let minutes = minutesBeforeStart
        if minutes < 60 { return L("予定の\(minutes)分前に通知します。") }
        if minutes < 60 * 24 { return L("予定の約\(minutes / 60)時間前に通知します。") }
        return L("予定の約\(minutes / (60 * 24))日前に通知します。")
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let savedEvent: CalendarEvent
        if let event {
            event.title = cleanTitle
            event.kind = kind
            event.startDate = startDate
            event.endDate = endDate
            event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            event.reminderDate = remindersEnabled ? effectiveReminderDate : nil
            event.reminderMinutesBefore = remindersEnabled ? minutesBeforeStart : -1
            savedEvent = event
        } else {
            let created = CalendarEvent(
                title: cleanTitle,
                startDate: startDate,
                endDate: endDate,
                kind: kind,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            created.reminderDate = remindersEnabled ? effectiveReminderDate : nil
            created.reminderMinutesBefore = remindersEnabled ? minutesBeforeStart : -1
            modelContext.insert(created)
            savedEvent = created
        }
        try? modelContext.save()
        Task {
            await UniversityCalendar.requestNotificationPermission()
            await EventReminderNotifications.schedule(for: savedEvent)
        }
        dismiss()
    }
}
