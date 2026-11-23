import XCTest
@testable import PenCore

final class BNFCodecTests: XCTestCase {
    // Raw firmware-derived v10 parameters; source BNF SHA256
    // e6ab1d24733a2074f40169f637bd91a731f614a70a8071bfa9ada3e9a85a1a71.
    // Expected audio bytes come from independently decoded original MIS.
    func testOriginalHeaderDerivesCodecWithoutSampleParameters() throws {
        var header = Data(repeating: 0, count: 65536)
        header.replaceSubrange(0xb0..<0xc8, with: "SS_Book_Code".data(using: .utf16LittleEndian)!)
        header.replaceSubrange(0..<32, with: hex("0a00fa030c70981effffffffffffff037a5fec4339ecdb853e346bcf35c9fb76"))
        header.replaceSubrange(9728..<10240, with: hex("35ba05b7b1238717363c1c3e855803813eb2dff7522bce849fafb1835c509dc32d28d85350f91a9d906e3adf7e1485fc430592720cf5ee5f3eb0785b34e10c5ecab6def82889ebd729b10d9a4fa2ae879f4c697bd1ffe333f2c46126988654861856c47d824fbbef40154494cee6cfdbd16bcee8b0fa092a4ce57e4205f3d03789b9411d6bb715cb7ba27f431da322be405ad13ac672ac83aeca65fff2d742343dcded2ace9ddb877e5722e002fadf143445c582bb1375b34fd33240c12a1db18714145664eaea0e9cbf14a02111ae0d80cdbdf7841a9c0939c0f4a61f591b4d291cc4d75012f6c1c3538d58f945508f6c78511d99722dff62b8fe0c1d818118cdb5edb1db055030eb2b99f16dab54bcec990a1fbd2e977a417c55b6b0fde9a061f75e7d86a939ebdf628fac3cfe416644fc0aaca999bf18f5876b264ab15a082fb3ab58d26183683a4bd677cab5bbbb28a1ac4193d10b461442e8c76c3fc11dcabacedc740bc31e79df2676d75c5c951ba9864d5a842c44d7e6971a5d718f21f70e7635c932e0a8bb78d0507c4615d3e184e3f207d9f4c890e2b53efb00cab2b66f2e372d626402536e2b8d75175b9fe721cfda710930ebf0d6b2d3a78d41897a1f6652c37bd9fed1e148556d8472ff621a95b061ca95cd011f62c251f53095662a88e6bbce51909ed3b32bf3ae398af36a94be40c1721b7248285109651558"))
        header.replaceSubrange(19456..<19968, with: hex("092152a1ea51f0f844602615b196bb98f9e860a5741c3d693690852fce0f69cf88d9ce649efa5f9d8e2aebcde3e248c61896d3913d23a08354d9ab741c88785ecf09fbcb600351b92ce34670c18c8922e9668e8ae7800d36f0001e21b95d8370ab1f60d579f0383445089d1e80daa3c1c0ffd2db690786693eda1e25751792dfff6d74b08b141886787169b504af2db638afdf446f4a505687c167de1606ef412664ad618d74591cb7eb3148844dd5fbc504d41d92c581ffb4ac68276df6296dfdb09afc9bcf8ee64390a300fd2e12d56497ad988f8ec053a03fabb0167f174aceef8b40b9182521a8905c98f01991116722844137ba409bdd7fd444b00362b6e0485c1133725a6d2820a8d9c97ac59242026cf9ba905582e957e31f503f4a71426e71a55d5563b84f3b17de718d283d03f416357ed04cd284aec0a218c761844861dfb20f4e599256f81e3ef73978386254021f331151bcd97b50e1542ba99a8c6dd990a66a2d7fbdf7b61f65b3428286ffc8164ad5d0dda3e032da40c26d5cccf8b8a181176ac81bd6b5c51a9f129b1f401846f3157923a7f9b1fb6e277f96ea4d10a403980e210a13a10647f2e233ac2ac3ef79d05721e055f7f991cbbf5b68eef0293e1ae436d4ad79c95816b4a21a7c6b348da2d0e4d1fd2e7f57403f2c8ef0a72ee8c6f5b557dae10d756f78694d9fa10246b798b453593e7b4caf5d36"))
        let parsed = try BNFCodec(fileHeader: header)
        XCTAssertEqual(parsed.bodyStart, 26624)
        // Native code XORs only the first 40 key-table bytes. A selector in
        // the final 20 bytes must read its key without an additional XOR.
        var alternate = header
        var metadata = try parsed.headerBlock(header.subdata(in: 19456..<19968), decrypt: true)
        let primary = UInt32(parsed.parameters.keys[0][0]) | UInt32(parsed.parameters.keys[0][1]) << 16
        for i in 0..<4 {
            metadata[0x36 + 4 + i] = UInt8(truncatingIfNeeded: UInt32(12) >> (i * 8)) ^ 0xac
            metadata[0x36 + 48 + i] = UInt8(truncatingIfNeeded: primary >> (i * 8))
        }
        alternate.replaceSubrange(19456..<19968, with: try parsed.headerBlock(metadata, decrypt: false))
        XCTAssertEqual(try BNFCodec(fileHeader: alternate).bodyStart, parsed.bodyStart)
        let previous = try BNFCodec(parameters: parameters())
        let original = hex("5a12d1ef50b56b444921216cb5e1faa111cf60a70092cedfe611fa84bba75e29ecd5bb3704e491ce930be0acb535016673eb14702dc21234f89fae495a56850a67131d06cdb871dec61e60daf600b63d012cba2335eee6aec0b8c6a7f7733be4ffe71fb2ce100b13a0a4f25ea36f71b9e9f94b5f198120d9c2df14798374c218d50c9ac9f2c17f9430fb11f6d9168cd0d7fc827b8b86c6512afb6830c6dafd7bb9f70304539b81f2729a02c5f239be1c15313164c956c3050c5c0120e9a8b8f9cf01f4510448c97c418b95d86d87ff13e6692fd534218aeed7d7c60c920be693490ddfb0127b653cee8c8524b093b88352d2209dc4938040d482c7ddb28a00c6ac7ea6c55f621c27e855312aad60cfccec6be66d18bf475430bb2ac542f33ec439f9c6ca26dad5297cc595fb99813976b39ddf5b8ec1e8470012c0ba2333dd56b8af733579c047d4d8bd796f88d00abc74a47e4c9bb79eecddd3d2c7331bc99f3c61c4e9fdfc6267cc13b5f9f310cf179fc2692d9d66d981a5195196d0e71f63d2d8230c400d2e545a8f9bf654bb51ce3c1fe18f18bb01dc3e941a6baf1d29451d4afa9088a3b7b831de770ef0c819fc84efeba9fb48044424203d28da6f2c6252f7e6fa74e3a99d329f11778a3a8d8b8e3abd8e1cd86661e58c8600e6b3cc42d37d9ed9ddb881a1598081c1473c16b083f942a955168ec65ca4383804f0cbc4")
        let plain = try parsed.decodePage(original, absoluteOffset: 681984, isMediaFirstSector: true)
        XCTAssertEqual(plain, try previous.decodePage(original, absoluteOffset: 681984, isMediaFirstSector: true))
        XCTAssertEqual(try parsed.encodePage(plain, absoluteOffset: 681984, isMediaFirstSector: true), original)
        XCTAssertThrowsError(try BNFCodec(fileHeader: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try BNFCodec(fileHeader: header.prefix(100)))
    }

    private func parameters() throws -> BNFCodecParameters {
        try BNFCodecParameters(sbox: Array(hex("5ac175fa77beaa2c21b31f96c85020c27dab2ec4d78081b97992ef060230403e04e84e8fb47f2444c923382dd2da4860ad8910a049c008ed70ccae128c1be639295b28ac4c4b9b696db2e9df4ff10c4255e2856ecd90975e86e3d31a6f7c63172a992f66ca19930efc53d0e4d9220367a5a8ddf658a63a73683df2560ab10ff96157885176bd64eaba457eb794ec71a937053200b8368aa316871c0726724d3f9afdcec665786b43dc746a9cd5159eb0fb6c985f2b5d137a9147f3a109b6e5de34ffe046e19dd8c3c5d4bc1da4bf83e741a7bbf418cff0d61133548e0dcb5c278d621ef701353cdbeb0ba2fe4a258259957b84143b52f5b59f8b31eed1c7aff8")),
            keys: [[19590, 19590, 0], [58722, 24344, 47738], [26044, 380, 25792], [20224, 43106, 59234]], rotations: [10, 14, 0])
    }

    private func hex(_ string: String) -> Data {
        let bytes = Array(string.utf8)
        precondition(bytes.count.isMultiple(of: 2))
        func digit(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        return Data(stride(from: 0, to: bytes.count, by: 2).map { digit(bytes[$0]) * 16 + digit(bytes[$0 + 1]) })
    }

    func testOriginalMediaFirstSectorDecodesAndReencodesExactly() throws {
        let codec = try BNFCodec(parameters: parameters())
        let cipher = hex("5a12d1ef50b56b444921216cb5e1faa111cf60a70092cedfe611fa84bba75e29ecd5bb3704e491ce930be0acb535016673eb14702dc21234f89fae495a56850a67131d06cdb871dec61e60daf600b63d012cba2335eee6aec0b8c6a7f7733be4ffe71fb2ce100b13a0a4f25ea36f71b9e9f94b5f198120d9c2df14798374c218d50c9ac9f2c17f9430fb11f6d9168cd0d7fc827b8b86c6512afb6830c6dafd7bb9f70304539b81f2729a02c5f239be1c15313164c956c3050c5c0120e9a8b8f9cf01f4510448c97c418b95d86d87ff13e6692fd534218aeed7d7c60c920be693490ddfb0127b653cee8c8524b093b88352d2209dc4938040d482c7ddb28a00c6ac7ea6c55f621c27e855312aad60cfccec6be66d18bf475430bb2ac542f33ec439f9c6ca26dad5297cc595fb99813976b39ddf5b8ec1e8470012c0ba2333dd56b8af733579c047d4d8bd796f88d00abc74a47e4c9bb79eecddd3d2c7331bc99f3c61c4e9fdfc6267cc13b5f9f310cf179fc2692d9d66d981a5195196d0e71f63d2d8230c400d2e545a8f9bf654bb51ce3c1fe18f18bb01dc3e941a6baf1d29451d4afa9088a3b7b831de770ef0c819fc84efeba9fb48044424203d28da6f2c6252f7e6fa74e3a99d329f11778a3a8d8b8e3abd8e1cd86661e58c8600e6b3cc42d37d9ed9ddb881a1598081c1473c16b083f942a955168ec65ca4383804f0cbc4")
        let expected = hex("fffb54c4000000000000000000000000000000000058696e670000000f0000006c000071d00004040405080c0f121416191b202325282a2c2f3134383b3d4245474a4c4e515356595c5e6166686a6d6f727477797c7e8186888b8d8f929497999d9fa2a4a9abaeb0b3b5b8babcbfc1c4c9cbced0d2d5d7dadcdfe1e4e6ebeef0f2f6f6f6f6f7f8f8f90000002c4c414d45332e383200000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffb14c40003c000019e1c000000000033c2800000ff791db3bb734d0ff91cb0c7c2c586bfe862e4c504c0f92e6a0df8100f9132266019081b6c234ecca2986290b17f9a1a3a06821710049a105c6afeb4d23127cae1b3871e2c418f89b8098ffffb74c425801bfa28dc19b980004a00e143860000fb26fa714f1470d5031816c06d103ff7bd059b9f200035306ea1150b9c138085003b7ffb267d8dcdd0bac1bae2dc16181fb87e819205c009c05920635fffd35ba068b7374133ec6e1a585fe0371853c09205701b982ca18f1d017382e706c19ffffffff2ba16db7533a2995d04d3537ff86881c88362c3e83ac4ee2d62c64505181b7030a06ad02c70320036e0fcc83084c0dc03460a67fffefffffffffb3fff7fdbfffabffdfa151c5ffdfffffd1feaff67ffd3fffffffeafffffa8f3fffff5ffffd5ffffffecffffffbb")
        let decoded = try codec.decodePage(cipher, absoluteOffset: 681984, isMediaFirstSector: true)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try codec.encodePage(expected, absoluteOffset: 681984, isMediaFirstSector: true), cipher)
        // Missing the extra whole-sector layer must not pass this real fixture.
        XCTAssertNotEqual(try codec.decodePage(cipher, absoluteOffset: 681984), expected)
    }

    func testOriginalLaterSectorDecodesWithoutFirstSectorLayer() throws {
        let codec = try BNFCodec(parameters: parameters())
        let cipher = hex("9cba63074fe751fe3cc07caeb6601e5fa8d69c3cab3ca17f79f0a1cc356b89a9e52a56d8c9e637dd822dd2a6e4d256d8359ee96a96d6d5e61e2659785416e72a97d63a02551f3895c12adca0d666e710f41f866441e5e731d816d6c6e42a56d8caf60d2b7416e9bf8b0ed4e6758cf69f4541617050e62fa61e65760036a836b3060f33951d42b6ba0c5f4b8214fe352fb06002c03388554d453af2dae450c62697d63a02981e32959921dc1f566f1b0df41fe66c42858dadbad7664c8bf5f581ad8cde211e9e59c3cc69b16ea70a5464fab8fa6170091a4a5549c85ca84f8d44eadd896d24db41f641cfa4a02f715fd5c45691a53a685a0c55b20aa4950bb9cd97d63a02869e25959921dc1f566f2d11452083a4559cea1496efd26b39a29988b483889287dbc2f6d4f129925161bf24b5cbf4971dc6cf43c7b98e15b8e4bbb40c52cc4dc6c1b2cdfd252bfd05fa3401b900500c394d92b5bbb82932861d92e597d6ba00e89eb85039f9df03743eaeda599e1280ee4a7e5c225392f7c1d41f2b36b773033fbbbc9d5c75743bbb4f3a15aca343dcf1034fe90e61a509a5505ac109698f01603c5fc1552b1d0d5cdf2eb9506fe0213c746b7740b08674f93b048cfbf50f29e357eddc450e1e6914974611c52f7adfd0125a917c2ffbc8ce191c4d021234d9b90f8b39f2ed4e6ffeac0865d432f95a948182efbb611ec84481cfe7")
        let expected = hex("fcaa1180597fffffffffffffeeff67fb7fff67fe906e1efffffffbffeffa7ffd7fffffffffffaf4d2611feafff57ffff5fedfd3fffffffffa3fa7ff40a43fffffffb14c43183c278030e00013fc043802180000000fffff67ffaffb7ffffffffffbbd1fffd4a80f5699339c66fe1ee00660562188cba065b9edf6ea11f7fd7a8bf93c24cdc142e6f5b2818640ca25a45845cda60054c5f1161eee94fa7501efbfffb14c44483c250070c008041c04c812180218000a75172686f63d169aa95448ee106863ee0dcf4323e5854ba8688c48e6f04dca99eb6f1b3161ccda8b969177a4224345a32a5aae713732c8b31c39bb053557a1f709cc631760e2ffe062d52fffb14c45703c284070c008041c051006180000bf8e2f295defebede3006b0f48b245c178d3bfabb36b6d6b4571c278543438723015a8dddf46a568a9376746b6ad6a529f4b42a52916550456cae924aa904949cea752eab296956b5b4cd4abafffb74c46803d079dafa07a46f49f1b2e0029ed001d666cd6491aebbed552a9d14ab6ba4aa1b352d15356b492491a2954ea79a72f6a433da34dc399e6a855cb4723994dee1558761b4c54d011543725fbf5904862268a09bcc704000f20ad81c896a498eb0c8e1a33d01c63903c85bc065f01b6eeb40821141694476988ea2e97cc0a849a876288a87b25b2089a9dcc534c9c4122e265c0ec09cc6586608b97f")
        XCTAssertEqual(try codec.decodePage(cipher, absoluteOffset: 682496), expected)
        XCTAssertEqual(try codec.encodePage(expected, absoluteOffset: 682496), cipher)
        XCTAssertNotEqual(try codec.decodePage(cipher, absoluteOffset: 682496, isMediaFirstSector: true), expected)
    }

    func testOriginalPagePrefixesAcrossAllTwelvePhases() throws {
        let codec = try BNFCodec(parameters: parameters())
        let fixtures: [(Int, String, String)] = [
            (688128, "9652fb076abb5dc32cfc7bc1f8c7ea877657f8ce6b33f63dd5ab621b17e2363f", "185cc7fffffffe9040e520002102003293151c097b186596a8f88c3850cd9fe1"),
            (686080, "ed7c816d2fe38cd9954bd54078491b02c90cc42e47bf23291f0dcb99f6c3fac4", "2945829b98aee5d658e73488d69cc38dfd5b985efd2efa63073d3d57aba702a5"),
            (684032, "ef1fa9445c1af1b14adb86d17e3e6cd1effee7d468e52b7c14a6d31e6bedf087", "7618a588558000000000000042fc3e00fffb74c4058190b5614bcd3d1101fd2a"),
            (686592, "a425e6af0732c2a2c42aaad9e732cb4fc67b5a6c594975e533f53a13a278073f", "c8ca0b2a1b55638b016bb8633d21ef1850ef814b86b516be39fc4368f426ba80"),
            (684544, "a089265e337883d213341214732ec6331898e02bb573c43f80fb10cab18d435c", "6d7c9948d51da1899b52909309bce1449461d25d0cee6dd58a2198f6ec984467"),
            (688640, "16bf5951a595311478472e60c11b5f4529ea66fa3c12dad93ee3674b9fa2349c", "403c908c77adb3d1d77fa2f2e875d98830e7bb38273934860fb9ad5dc72dc77f"),
            (685056, "71031b66acc95d8147e4634db6ed9623fd6b7b107a3b1eb5b35828335b76993b", "f84e7f5f0e73f8d5b5b89a82a784e6e656663daa0340a3545bcf7ce26f4389bd"),
            (683008, "563029b9c6f19cd0cd141e3dd9004cdd6074a6c783cf6046cc432a567be85004", "4d9165acb0ab9205f1742a0388842f9b93a8dd3f532d475cc1d21d64f9364590"),
            (687104, "bac7d36e46442f3faf92036294357a480d91ebd18dbef1d4c658fa52e72b82fa", "a2fcefce4ee77790559eefbf337ed56988ee70d3c8d5109e4a0ae669c21159c9"),
            (683520, "c01d026b9f5065b00a3ec3a63fb4241a781a5a99635200f8e75f9230db71a126", "916166d8fc30c3bace5dbc357e532cc2b56caa5ce679e7cdf70de57798775f7b"),
            (687616, "421d3cbe3351b735f45aef7c2adeed8a4fafa010a9d78caf3f95195f82b5b4ff", "ffa14b423980cfef91a2ecc4b2e90826de22e9b1131e004d3cf40859654976d9"),
            (685568, "d02482d9e805905e61c290064f0a6843f436dbdd5955bbb1fccab605244bb69f", "a19169400000000000000013b633a477a11dc5d72c470ae4da530d53adc8537d")
        ]
        for (offset, cipherHex, plainHex) in fixtures {
            let cipher = hex(cipherHex), plain = hex(plainHex)
            XCTAssertEqual(try codec.decodePagePrefix(cipher, absoluteOffset: offset), plain, "offset \(offset)")
            XCTAssertEqual(try codec.encodePagePrefix(plain, absoluteOffset: offset), cipher, "offset \(offset)")
        }
    }

    func testInvalidParametersAndPageBoundariesAreRejected() throws {
        let p = try parameters()
        XCTAssertThrowsError(try BNFCodecParameters(sbox: [UInt8](repeating: 0, count: 256), keys: p.keys, rotations: p.rotations))
        XCTAssertThrowsError(try BNFCodecParameters(sbox: p.sbox, keys: [[1, 2, 3]], rotations: p.rotations))
        XCTAssertThrowsError(try BNFCodecParameters(sbox: p.sbox, keys: p.keys, rotations: [0, 16, 1]))
        XCTAssertThrowsError(try BNFCodec(parameters: p, rc6Key: Data(repeating: 0, count: 15)))
        let codec = try BNFCodec(parameters: p), page = Data(repeating: 0, count: 512)
        XCTAssertThrowsError(try codec.decodePage(Data(), absoluteOffset: 0))
        XCTAssertThrowsError(try codec.encodePage(page, absoluteOffset: -512))
        XCTAssertThrowsError(try codec.decodePage(page, absoluteOffset: 2))
        XCTAssertThrowsError(try codec.decodePage(page, absoluteOffset: Int.max - 511))
        XCTAssertThrowsError(try codec.decodePagePrefix(page, absoluteOffset: 0))
        XCTAssertThrowsError(try codec.encodePagePrefix(Data(), absoluteOffset: 0))
    }
}
