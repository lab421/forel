// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Testing
@testable import ForelCore

@Suite struct FileFingerprintTests {
    @Test func databaseIntegerPreservesOrdinaryFilesystemIdentifiers() {
        #expect(FileFingerprint.databaseInteger(UInt64(42)) == 42)
        #expect(FileFingerprint.databaseInteger(Int32(7)) == 7)
    }

    @Test func databaseIntegerSafelyStoresUnsignedIdentifiersUsingTheHighBit() {
        #expect(FileFingerprint.databaseInteger(UInt64(Int64.max) + 1) == Int64.min)
        #expect(FileFingerprint.databaseInteger(UInt64.max) == -1)
    }
}
