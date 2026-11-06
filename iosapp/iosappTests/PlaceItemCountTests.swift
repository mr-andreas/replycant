import Testing
@testable import iosapp

// A place tile's subtitle is the only count a person sees for that
// cluster. One photo has to read as a single item.
struct PlaceItemCountTests {
    @Test func onePhotoUsesTheSingular() {
        #expect(placeItemCountSubtitle(1) == "1 item")
    }

    // Zero and every larger count keep the title-style plural the
    // subtitle already used.
    @Test func otherCountsStayPlural() {
        #expect(placeItemCountSubtitle(0) == "0 Items")
        #expect(placeItemCountSubtitle(2) == "2 Items")
        #expect(placeItemCountSubtitle(1800) == "1800 Items")
    }
}
