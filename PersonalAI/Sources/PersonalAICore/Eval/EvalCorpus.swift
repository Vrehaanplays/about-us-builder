import Foundation

/// A hand-written "life" used to evaluate the whole memory pipeline (import → index → retrieve → assemble → grounded answer).
/// Needles are buried inside long, topically *similar* chatter so that finding them requires retrieval, not luck.
/// It is small and synthetic: it measures behaviour (paraphrase, time, names, corrections, abstention), not real-world accuracy.
public struct EvalCorpus: Sendable {
    public struct Line: Sendable {
        public var role: Role; public var text: String; public var key: String?
        public init(role: Role, text: String, key: String? = nil) { self.role = role; self.text = text; self.key = key }
    }
    public struct Conv: Sendable {
        public var name: String; public var title: String; public var start: String; public var lines: [Line]
        public init(name: String, title: String, start: String, lines: [Line]) { self.name = name; self.title = title; self.start = start; self.lines = lines }
    }

    public struct Case: Sendable {
        public var id: String
        public var category: String
        public var query: String
        public var gold: [String]              // message keys that must be retrieved as evidence
        public var mustContain: [String]       // answer must contain each (case-insensitive)
        public var mustNotContain: [String] = []
        public var abstain = false
        public var now: String = "2025-09-01T12:00:00Z"
        public var inConversation: String? = nil     // ask from inside this conversation (continuity)
        public var hardWindow: (String, String)? = nil
    }

    public var conversations: [Conv]
    public var cases: [Case]
    public init(conversations: [Conv], cases: [Case]) { self.conversations = conversations; self.cases = cases }
    public var now: Date { Date(timeIntervalSince1970: Self.ts("2025-09-01T12:00:00Z")) }

    public static func ts(_ s: String) -> Double {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }

    // MARK: filler (similar in topic to the needles on purpose, never containing the answer)
    static let renovation = [
        "The plasterer can start on the hallway once the electrics are signed off.", "We need to decide between matt and satin for the skirting boards.",
        "The skip arrives on Tuesday so clear the side passage tonight.", "Can you compare underfloor heating options for the kitchen extension?",
        "The builder says the steel beam delivery slipped by a week.", "I measured the alcove again and it's a few millimetres narrower than the plan.",
        "What undercoat works on old pine door frames?", "The tiler recommended a flexible adhesive for the splashback area.",
        "We still haven't chosen worktops, quartz looks heavy but easy to clean.", "Remind me to ask about building regs sign-off for the extension.",
        "The cabinet maker wants a deposit before cutting the carcasses.", "Noise from the grinder meant I worked from the library today.",
        "Pendant lights over the island should hang about 75cm above the surface.", "Is a 600mm hob enough or should we go for 700?",
        "Painters are quoting by the day, not by the room, which is annoying.",
    ]
    static let thesis = [
        "I rewrote the literature review section on attention mechanisms again.", "Chapter three still needs a clearer statement of the research question.",
        "My supervisor suggested cutting the appendix on tokenisation by half.", "Can you check whether this citation style matches the department template?",
        "The ablation table has an inconsistent number of seeds across rows.", "I should rerun the baseline with the corrected learning rate schedule.",
        "Need to proofread the acknowledgements, I always overthink them.", "The figure captions are too long, shorten them to one sentence each.",
        "Explain the difference between held-out and cross-validated evaluation once more.", "I'm worried the related work reads like a list rather than an argument.",
        "Save the final dataset split in the repository so it's reproducible.", "The reviewer comments on the workshop paper were mostly about clarity.",
        "Let's outline the discussion section around three limitations.", "Format the bibliography with hanging indents.", "Remind me to back up the thesis folder to the external disk.",
    ]
    static let travel = [
        "Look for a quiet area with good public transport links.", "Is it worth getting a city pass or just paying per attraction?",
        "What's a realistic daily food budget for two people?", "Summarise the best day trips from the city by train.",
        "I'd like at least one rainy-day plan with museums.", "Check whether the airport train runs overnight.",
        "Travel insurance quotes seem to vary wildly, explain what's usually covered.", "Suggest a walking route that avoids the steepest hills.",
    ]
    static let running = [
        "My knee felt a bit tight after the long run on Sunday.", "What's a sensible weekly mileage increase for a returning runner?",
        "I switched to a different pair of shoes for tempo days.", "Remind me to book a physio check before the autumn race season.",
        "Heart rate drifted upward in the last third again, humid evening.", "Explain how to structure a taper over two weeks.",
    ]

    static func filler(_ pool: [String], _ n: Int, seed: Int) -> [String] {
        var out: [String] = []
        var s = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        for i in 0..<n {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let base = pool[Int(s >> 33) % pool.count]
            let tail = ["", " Keep it short.", " (second thought, later.)", " Thanks.", " No rush on this one.", " Does that make sense?"][Int(s >> 20) % 6]
            out.append(base + tail + (i % 5 == 0 ? " Item \(i)." : ""))
        }
        return out
    }

    static func long(_ name: String, _ title: String, _ start: String, pool: [String], count: Int, needles: [Int: (Role, String, String)], seed: Int) -> Conv {
        let f = filler(pool, count, seed: seed)
        var lines: [Line] = []
        for i in 0..<count {
            if let n = needles[i] { lines.append(Line(role: n.0, text: n.1, key: n.2)); continue }
            lines.append(Line(role: i % 2 == 0 ? .user : .assistant, text: i % 2 == 0 ? f[i] : "Understood. Here is a short note on that, with the main points listed in order.", key: nil))
        }
        return Conv(name: name, title: title, start: start, lines: lines)
    }

    static func short(_ name: String, _ title: String, _ start: String, _ items: [(Role, String, String?)]) -> Conv {
        Conv(name: name, title: title, start: start, lines: items.map { Line(role: $0.0, text: $0.1, key: $0.2) })
    }

    public static let standard: EvalCorpus = {
        var c: [Conv] = []
        c.append(long("kitchen", "Kitchen renovation", "2025-02-03T09:00:00Z", pool: renovation, count: 700,
                      needles: [143: (.user, "We settled on the oak herringbone floor for the kitchen, the supplier quoted 4,200 pounds including fitting.", "kitchen#floor")], seed: 1))
        c.append(long("thesis", "Thesis writing", "2025-04-02T08:00:00Z", pool: thesis, count: 900,
                      needles: [61: (.user, "Reminder to self: the committee meeting got moved to the 14th of November at 3pm in room B204.", "thesis#defense")], seed: 2))
        c.append(short("trip-flights", "Portugal flights", "2025-01-10T09:00:00Z", [
            (.user, "I booked flights for the Portugal trip with TAP, leaving on 12 April.", "flights#tap"), (.assistant, "Nice, TAP has decent legroom on that route.", nil)]))
        c.append(long("trip-hotel", "Lisbon hotel", "2025-02-14T18:00:00Z", pool: travel, count: 40,
                      needles: [11: (.user, "The hotel in Lisbon is Casa do Largo, 95 euros a night with a terrace.", "hotel#largo")], seed: 3))
        c.append(short("job-a", "New role", "2025-03-04T10:00:00Z", [
            (.user, "I work at Brightwell Analytics as a data engineer.", "joba#brightwell"), (.assistant, "How are you finding the team?", nil)]))
        c.append(short("job-b", "Career update", "2025-07-18T10:00:00Z", [
            (.user, "Big news, I just started a new job. I work at Helix Robotics now.", "jobb#helix"), (.assistant, "Congratulations!", nil)]))
        c.append(long("run-jan", "Running log January", "2025-01-20T07:00:00Z", pool: running, count: 30,
                      needles: [9: (.user, "Ran my 10k today in 52 minutes, felt heavy.", "run#jan")], seed: 4))
        c.append(long("run-aug", "Running log August", "2025-08-12T07:00:00Z", pool: running, count: 30,
                      needles: [7: (.user, "Ran the 10k in 47 minutes this morning, a new personal record.", "run#aug")], seed: 5))
        c.append(short("bookclub", "Book club", "2025-05-06T20:00:00Z", [
            (.user, "Priya recommended The Overstory for book club next month.", "book#priya"), (.assistant, "A good pick for a discussion group.", nil)]))
        c.append(short("alex-work", "Work chat", "2025-04-01T10:00:00Z", [
            (.user, "Alex from work wants the quarterly slides by Friday and keeps changing the template.", "alex#work"), (.assistant, "That sounds frustrating.", nil)]))
        c.append(short("alex-bro", "Family", "2025-04-20T10:00:00Z", [
            (.user, "My brother Alex is moving to Porto next month and asked if I could help him pack.", "alex#bro"), (.assistant, "Porto is lovely.", nil)]))
        c.append(short("health", "Diet notes", "2025-02-14T12:00:00Z", [
            (.user, "I'm allergic to cashews so please never suggest recipes with them.", "health#cashew"), (.assistant, "Understood, no cashews.", nil)]))
        c.append(short("old-car", "Old memories", "2023-06-05T19:00:00Z", [
            (.user, "My first car was a green 2004 Honda Civic that I bought for 2,300 dollars.", "car#civic"), (.assistant, "A Civic is a great first car.", nil)]))
        c.append(short("spice-old", "Food preferences", "2024-03-02T19:00:00Z", [
            (.user, "I love spicy food, the hotter the better.", "spice#love"), (.assistant, "Noted, I will lean on chilli.", nil)]))
        c.append(short("spice-new", "Food update", "2025-06-22T19:00:00Z", [
            (.user, "I can't handle spicy food anymore since my surgery.", "spice#cant"), (.assistant, "I'll keep recipes mild.", nil)]))
        c.append(short("locker", "Gym", "2025-05-30T07:00:00Z", [
            (.user, "My gym locker code is 4417.", "gym#locker"), (.assistant, "Got it.", nil)]))
        c.append(short("dentist", "Appointments", "2025-08-20T08:00:00Z", [
            (.user, "Dentist appointment is on 3 October at 9:30.", "dentist#date"), (.assistant, "I'll remember that.", nil)]))

        func k(_ id: String, _ cat: String, _ q: String, gold: [String], has: [String], not: [String] = [], abstain: Bool = false, conv: String? = nil, hard: (String, String)? = nil) -> Case {
            Case(id: id, category: cat, query: q, gold: gold, mustContain: has, mustNotContain: not, abstain: abstain, inConversation: conv, hardWindow: hard)
        }
        let cases: [Case] = [
            k("floor-exact", "exact", "what did the supplier quote for the oak herringbone floor", gold: ["kitchen#floor"], has: ["4,200"]),
            k("floor-para", "paraphrase", "how much was the estimate for the wooden flooring in the cooking area", gold: ["kitchen#floor"], has: ["4,200"]),
            k("defense-para", "paraphrase", "when and where is my thesis committee gathering", gold: ["thesis#defense"], has: ["14th of November", "B204"]),
            k("allergy-para", "paraphrase", "which tree nuts should recipes for me avoid", gold: ["health#cashew"], has: ["cashews"]),
            k("dentist-para", "paraphrase", "when do I have to see the tooth doctor", gold: ["dentist#date"], has: ["3 October"]),
            k("car-old", "old-conversation", "what was the first vehicle I ever owned", gold: ["car#civic"], has: ["Honda Civic"]),
            k("locker", "identifier", "what's the combination for my gym locker", gold: ["gym#locker"], has: ["4417"]),
            k("trip-cross", "cross-chat", "what arrangements have I made so far for the Portugal holiday", gold: ["flights#tap", "hotel#largo"], has: ["TAP", "Casa do Largo"]),
            k("floor-continue", "cross-chat", "back to the flooring: which wood did we pick and what did it cost", gold: ["kitchen#floor"], has: ["oak herringbone", "4,200"], conv: "trip-hotel"),
            k("run-jan", "date-range", "how fast was my 10k in January 2025", gold: ["run#jan"], has: ["52 minutes"], not: ["47"], hard: ("2025-01-01T00:00:00Z", "2025-02-01T00:00:00Z")),
            k("run-latest", "recency", "what's my most recent 10k time", gold: ["run#aug"], has: ["47 minutes"], not: ["52"]),
            k("job-now", "correction", "where do I work", gold: ["jobb#helix"], has: ["Helix Robotics"], not: ["Brightwell"]),
            k("spice-now", "conflict", "do I like spicy food", gold: ["spice#cant"], has: ["can't handle"], not: ["love spicy"]),
            k("priya", "name", "which book did Priya suggest", gold: ["book#priya"], has: ["The Overstory"]),
            k("alex-bro", "name-ambiguity", "what did my brother Alex ask me to do", gold: ["alex#bro"], has: ["pack"], not: ["slides"]),
            k("alex-work", "name-ambiguity", "what does Alex from work keep changing", gold: ["alex#work"], has: ["template"], not: ["Porto"]),
            k("abstain-passport", "abstain", "what is my passport number", gold: [], has: [], abstain: true),
            k("abstain-sister", "abstain", "what did I say about my sister's wedding", gold: [], has: [], abstain: true),
            // ---- held-out: written after retrieval tuning had stopped; never used to choose a threshold ----
            k("h-car-price", "heldout", "how much did I pay for my first car", gold: ["car#civic"], has: ["2,300"]),
            k("h-hotel-rate", "heldout", "which hotel am I staying at in Lisbon and what is the nightly rate", gold: ["hotel#largo"], has: ["Casa do Largo", "95"]),
            k("h-alex-deadline", "heldout", "when does Alex at the office need the presentation", gold: ["alex#work"], has: ["Friday"], not: ["Porto"]),
            k("h-best-run", "heldout", "what is my best time over ten kilometres", gold: ["run#aug"], has: ["47 minutes"]),
            k("h-food-avoid", "heldout", "which ingredient should never be served to me", gold: ["health#cashew"], has: ["cashews"]),
            k("h-employer", "heldout", "who is my current employer", gold: ["jobb#helix"], has: ["Helix Robotics"], not: ["Brightwell"]),
            k("h-chilli", "heldout", "can I eat hot chilli dishes these days", gold: ["spice#cant"], has: ["can't handle"], not: ["love spicy"]),
            k("h-committee", "heldout", "what day does the committee meet and in which room", gold: ["thesis#defense"], has: ["14th of November", "B204"]),
            k("h-airline", "heldout", "which airline did I fly with for the Portugal trip", gold: ["flights#tap"], has: ["TAP"]),
            k("h-reading", "heldout", "what did Priya want the group to read", gold: ["book#priya"], has: ["The Overstory"]),
            k("h-floor-fit", "heldout", "what did the oak floor cost with installation", gold: ["kitchen#floor"], has: ["4,200"]),
            k("h-dentist-time", "heldout", "what time is my dental appointment in October", gold: ["dentist#date"], has: ["9:30"]),
            k("h-abstain-mother", "heldout", "what is my mother's birthday", gold: [], has: [], abstain: true),
            k("h-abstain-steps", "heldout", "how many steps did I walk yesterday", gold: [], has: [], abstain: true),
            // ---- second held-out batch (prefix "g-"): written after the first batch's failures were fixed; first-run result is reported as-is ----
            k("g-moved", "heldout2", "which city is my brother relocating to", gold: ["alex#bro"], has: ["Porto"], not: ["slides"]),
            k("g-vehicle-colour", "heldout2", "what colour was the car I started out with", gold: ["car#civic"], has: ["green"]),
            k("g-gym", "heldout2", "I forgot the number for the changing room cabinet at the gym", gold: ["gym#locker"], has: ["4417"]),
            k("g-spring", "heldout2", "when am I flying out in the spring", gold: ["flights#tap"], has: ["12 April"]),
            k("g-reno-budget", "heldout2", "remind me what the kitchen floor is going to set me back", gold: ["kitchen#floor"], has: ["4,200"]),
            k("g-slow-run", "heldout2", "how long did the run take me at the start of the year", gold: ["run#jan"], has: ["52 minutes"], not: ["47"], hard: ("2025-01-01T00:00:00Z", "2026-01-01T00:00:00Z")),
            k("g-novel", "heldout2", "name of the novel my friend suggested for our reading circle", gold: ["book#priya"], has: ["The Overstory"]),
            k("g-pet", "heldout2", "what is my dog called", gold: [], has: [], abstain: true),
            k("g-bank", "heldout2", "what is the pin for my bank card", gold: [], has: [], abstain: true),
        ]
        return EvalCorpus(conversations: c, cases: cases)
    }()
}
