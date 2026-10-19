import Foundation
import ShouCore

func sha256KnownVector() throws {
    try expect(Digest.sha256(Data("abc".utf8)) == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try expect(Digest.sha256(Data(repeating: 97, count: 1_000_000)) == "sha256:cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}
