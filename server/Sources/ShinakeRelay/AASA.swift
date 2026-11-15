import Foundation

/// Static association file served for local checks. Production copies
/// `server/deploy/apple-app-site-association` onto vajra.one so the yuguan
/// process is no longer the only writer of this URL.
enum RoomAASA {
    static let json = """
    {
      "applinks": {
        "apps": [],
        "details": [
          {
            "appIDs": ["A5VCS5XD6R.one.vajra.yuguan"],
            "components": [
              { "/": "/yuguan/join/*", "comment": "friend room invite" }
            ]
          },
          {
            "appIDs": ["A5VCS5XD6R.one.vajra.shinake"],
            "components": [
              { "/": "/shinake/join/*", "comment": "shinake duel invite" }
            ]
          }
        ]
      }
    }
    """
}
