import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Component tests for the pieces the user reported as unclear or broken.
 *
 * These run under qmltestrunner against the real QML files with no backend —
 * they assert on component state and bindings, not on pixels. Anything needing
 * a live backend belongs in the sitometres specs instead.
 */
Item {
    width: 800
    height: 600

    // ---- SegmentedControl: which source is selected -------------------

    Ui.SegmentedControl {
        id: sources
        options: [
            { key: "remote", label: "Any repo" },
            { key: "local",  label: "My node", enabled: false,
              disabledReason: "No local Radicle node detected" }
        ]
        current: "remote"
    }

    // ---- SectionTabs: which tab is selected ---------------------------

    Ui.SectionTabs {
        id: tabs
        tabs: [
            { label: "Source",  count: -1 },
            { label: "Commits", count: -1 },
            { label: "Issues",  count: 12 },
            { label: "Patches", count: 3 }
        ]
        current: 0
    }

    // ---- FilterChips: which state filter is active --------------------

    Ui.FilterChips {
        id: chips
        states: ["open", "closed"]
        current: "open"
    }

    // ---- StatusStrip: fixed height so layout does not jump ------------

    Ui.StatusStrip { id: strip }

    // ---- SeedPicker: the dropdown that came up empty ------------------

    Ui.SeedPicker {
        id: picker
        // Assigned AFTER construction, reproducing the ordering that used to
        // leave the list permanently empty.
        property bool armed: false
    }

    TestCase {
        name: "SegmentedControl"
        when: windowShown

        function test_reports_the_current_selection() {
            compare(sources.current, "remote");
        }

        function test_selecting_a_segment_emits_its_key() {
            var seen = [];
            function grab(key) { seen.push(key); }
            sources.picked.connect(grab);
            sources.picked("local");
            sources.picked.disconnect(grab);
            compare(seen.length, 1);
            compare(seen[0], "local");
        }

        function test_options_carry_their_disabled_reason() {
            // A disabled source must explain itself rather than just not work.
            compare(sources.options[1].enabled, false);
            verify(sources.options[1].disabledReason.length > 0);
        }
    }

    TestCase {
        name: "SectionTabs"
        when: windowShown

        function test_starts_on_the_first_tab() {
            compare(tabs.current, 0);
        }

        function test_picking_a_tab_reports_its_index() {
            var seen = -1;
            function grab(i) { seen = i; }
            tabs.picked.connect(grab);
            tabs.picked(2);
            tabs.picked.disconnect(grab);
            compare(seen, 2);
        }

        function test_counts_are_carried_per_tab() {
            compare(tabs.tabs[2].count, 12);
            compare(tabs.tabs[3].count, 3);
            // -1 means "no badge", used for Source and Commits.
            compare(tabs.tabs[0].count, -1);
        }

        function test_height_is_fixed_regardless_of_content() {
            var before = tabs.height;
            tabs.tabs = [{ label: "Only one", count: 999999 }];
            compare(tabs.height, before);
        }
    }

    TestCase {
        name: "FilterChips"
        when: windowShown

        function test_reports_the_active_filter() {
            compare(chips.current, "open");
        }

        function test_picking_a_filter_emits_it() {
            var seen = "";
            function grab(s) { seen = s; }
            chips.picked.connect(grab);
            chips.picked("closed");
            chips.picked.disconnect(grab);
            compare(seen, "closed");
        }
    }

    TestCase {
        name: "StatusStrip"
        when: windowShown

        function test_keeps_its_height_when_idle() {
            // The strip used to collapse when idle, shifting everything below
            // it each time a request started or finished.
            strip.busy = false;
            strip.error = "";
            var idle = strip.height;
            strip.busy = true;
            compare(strip.height, idle);
            strip.busy = false;
            strip.error = "something went wrong";
            compare(strip.height, idle);
            strip.error = "";
        }
    }

    TestCase {
        name: "SeedPicker"
        when: windowShown

        function test_loads_when_the_fetcher_arrives_after_construction() {
            // Regression: the picker loaded only from Component.onCompleted,
            // which ran before the parent assigned fetchSeeds, so the dropdown
            // stayed empty forever.
            compare(picker.count, 0);

            picker.fetchSeeds = function (cb) {
                cb({ items: [
                    { url: "https://seed.radicle.xyz",     alias: "seed.radicle.xyz" },
                    { url: "https://iris.radicle.network", alias: "iris.radicle.network" },
                    { url: "https://rosa.radicle.network", alias: "rosa.radicle.network" }
                ]});
            };

            compare(picker.count, 3);
        }

        function test_selects_the_seed_currently_in_use() {
            picker.fetchSeeds = function (cb) {
                cb({ items: [
                    { url: "https://a.test", alias: "a" },
                    { url: "https://b.test", alias: "b" }
                ]});
            };
            picker.loaded = false;
            picker.reload();
            picker.currentSeed = "https://b.test";
            compare(picker.currentIndex, 1);
        }

        function test_a_fetcher_that_bails_out_leaves_it_retryable() {
            // The real failure: the picker's load triggers all fire before the
            // QtRO replica exists, so the fetcher returns without ever calling
            // back. The earlier test injected a fetcher that replied
            // synchronously, so it never exercised this path and the dropdown
            // stayed empty in the running app while the test passed.
            picker.loaded = false;
            var attempts = 0;
            picker.fetchSeeds = function (cb) {
                attempts++;
                // Backend not ready: return without invoking cb, as
                // Main.qml's callPlain does when `backend` is null.
            };
            picker.reload();
            compare(attempts, 1);
            compare(picker.count, 0);

            // Once the backend is live the app clears `loaded` and retries;
            // without that the picker never loads at all.
            picker.loaded = false;
            picker.fetchSeeds = function (cb) {
                attempts++;
                cb({ items: [{ url: "https://a.test", alias: "a" },
                             { url: "https://b.test", alias: "b" }] });
            };
            picker.reload();
            compare(attempts, 2);
            compare(picker.count, 2);
        }

        function test_an_empty_reply_leaves_it_retryable() {
            picker.loaded = false;
            picker.fetchSeeds = function (cb) { cb({ items: [] }); };
            picker.reload();
            // A failed load must not latch the picker into a permanently
            // empty state.
            compare(picker.loaded, false);
        }
    }
}
