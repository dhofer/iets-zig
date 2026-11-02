//! Throwaway keys generated with OpenSSL 3.5 for the parsing and signing
//! tests (`openssl ecparam/genpkey/genrsa`, `pkcs8 -topk8 -nocrypt`, `pkey -pubout`).

pub const p256_sec1 =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIKtn7Iej3/jhU8e8GE4ZIr+jub4wJV7ALmNZ34aEqTcwoAoGCCqGSM49
    \\AwEHoUQDQgAEVxOviWpPL8n5n2RDIjKp1lzPOgoR73J7HOgG/uJF3sVJFqrbomnU
    \\IP/7L/c7TKC0jneeJb4zjqeIQ7yDE/i8Zg==
    \\-----END EC PRIVATE KEY-----
;

pub const p256_pkcs8 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgq2fsh6Pf+OFTx7wY
    \\Thkiv6O5vjAlXsAuY1nfhoSpNzChRANCAARXE6+Jak8vyfmfZEMiMqnWXM86ChHv
    \\cnsc6Ab+4kXexUkWqtuiadQg//sv9ztMoLSOd54lvjOOp4hDvIMT+Lxm
    \\-----END PRIVATE KEY-----
;

pub const p256_pub =
    \\-----BEGIN PUBLIC KEY-----
    \\MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVxOviWpPL8n5n2RDIjKp1lzPOgoR
    \\73J7HOgG/uJF3sVJFqrbomnUIP/7L/c7TKC0jneeJb4zjqeIQ7yDE/i8Zg==
    \\-----END PUBLIC KEY-----
;

pub const p384_sec1 =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MIGkAgEBBDD4ZabummACuziOIMOQrLlAzR8lpyuEXyhBD55foD/G98vu6S2cdMwM
    \\sCUJxjsDAyKgBwYFK4EEACKhZANiAATHW8oVkRA6/V9V+ehvDe2bcCln62wA1wJe
    \\ehdiXWquOKkmgpIORAwMsF4S51pLmBJP8s5Bm/CYndyAzYAzVUmLj6h1aeavBebA
    \\huo8XzqnireT2nNQ0vH0mjnH2CBwBMU=
    \\-----END EC PRIVATE KEY-----
;

pub const p384_pkcs8 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDD4ZabummACuziOIMOQ
    \\rLlAzR8lpyuEXyhBD55foD/G98vu6S2cdMwMsCUJxjsDAyKhZANiAATHW8oVkRA6
    \\/V9V+ehvDe2bcCln62wA1wJeehdiXWquOKkmgpIORAwMsF4S51pLmBJP8s5Bm/CY
    \\ndyAzYAzVUmLj6h1aeavBebAhuo8XzqnireT2nNQ0vH0mjnH2CBwBMU=
    \\-----END PRIVATE KEY-----
;

pub const p384_pub =
    \\-----BEGIN PUBLIC KEY-----
    \\MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEx1vKFZEQOv1fVfnobw3tm3ApZ+tsANcC
    \\XnoXYl1qrjipJoKSDkQMDLBeEudaS5gST/LOQZvwmJ3cgM2AM1VJi4+odWnmrwXm
    \\wIbqPF86p4q3k9pzUNLx9Jo5x9ggcATF
    \\-----END PUBLIC KEY-----
;

pub const ed25519_pkcs8 =
    \\-----BEGIN PRIVATE KEY-----
    \\MC4CAQAwBQYDK2VwBCIEIDLCbr4LoAwTMjEHV78+vHEwASFHY8/QaOOq8ipkp+iR
    \\-----END PRIVATE KEY-----
;

pub const ed25519_pub =
    \\-----BEGIN PUBLIC KEY-----
    \\MCowBQYDK2VwAyEA9wa3r4AcuQ2XKW7yqaHNsmj0RM7NivZwf4X592LYnIA=
    \\-----END PUBLIC KEY-----
;

pub const rsa_pkcs1 =
    \\-----BEGIN RSA PRIVATE KEY-----
    \\MIIEpAIBAAKCAQEA2JF8mqG0DE/RUHyCbCmSGFbijlBgUKnVSYNzgeiNWF6svBiV
    \\623YKnaMO8+vHj+Gf0rThO1AAqjK9l5K0jYOcIyUQfeoQ2XZwiHzrvdLlOscQE9G
    \\/wzN0zseGj00lWgsZwnzBbzczAgjCmWuF8iLLbkxGfhkrO8JMj/hDQPgd0Okl6dp
    \\xJzFfxFhItDECV9EVRsQgOLy9rUDMSDUT9XHJPQUu/HeMqLsAnon4ksvRUQ2MJss
    \\5m07VedUmjR87flh/TLRmhLFsaSuGjTZGw26yMAXWapXJWvlag+H+G6INVAer0hz
    \\XDiHKsR6Iepl3sJbxBYa4iLd6ZCgXlnoDv2JLwIDAQABAoIBAGYdV3D7/Q7vFcWL
    \\J94DTfEvCp1K9dci9UA3/J9M/VSlM3Jvb0U2on4HLsFHAI3VK0BbElgznAKE/0pi
    \\lIoA1hcomgFu2oaJAD/izWl7DkbWAxipqNK7AVPvpJZ/tIscNw+Qp+fVMRD9ZzRQ
    \\VGG/fCyfjTDvJ91Iyn/Ikf+Wi+D/hCa1gwlwc4ibdD+ocQLvAkBTfuE533rKYU9J
    \\1P71lmKPP2tlSlNNS9b9BYrPkTTrJCaafpBu3jMw2ZlxgNuhcSF12/ysHS6hW7D+
    \\jGDWtZslutGE+lztI9wkTUa1dT69/XmHl34eqzbqUNQaoXdtW1DOuj0x+8uqVfTV
    \\6SaUVc0CgYEA+kRNZl37VZmq/VIq7UUqAUKkWjUPQBXFys6HphaKKTdsQocPnowp
    \\RUdss68iMvT2cq1gUu1zyIFUKP8+9TVhm6Rwqp1ER5rgekSiTslHZ+BPwmDFgEQW
    \\k9Ga0122cbrhCZxaiLNB7HGo6FIRZuTunwZf7chSLQuYMaRtcqO3wAMCgYEA3YeO
    \\+B0j0SeBXXSxlKVIQr37TEETa6kaXVDIF7qyYtJZLzB5iUoZYJN8yqtmF1InBn1n
    \\nm/53rWMqAncgTItG2QSIVVKk8mxOXPKMRXIV3DSZxzspO0XytfvBFEQlx3XbTDP
    \\g0PUjpLFfRbUH8tEI0iqURKBq5rxy7RlGrR/mGUCgYEAouf7Cft7MwlISIVH9BLl
    \\eNSMbzvCpZCGo7E0k2Rwosu06MlJ3YaXBsWreHsz47+Y/KTm4pQ2nfmxcs5TiQIq
    \\e0nbHPQqEgI6xNwQWwCiPnfA82JSrV+k4qu6AIQr0nQ3MC5asEkfTG3f6Poi4bt7
    \\qIBZyUpwU2oMs6O4qrrvTUkCgYAocp3aE4f8olfudmYOG/eLqCCAFcmz+JZFv4Ap
    \\RP9ZJ8r84L7wIEVt6r/4ST9Ets1FVBRdS1i2HzPlYpeOR1kRDT56M5aAUW04bjnW
    \\qIGB5amlBhT3MAsOEEsl4J9E2EADQcxBzVq8BXRlmIt2mqiAQL5IOzbN3GaVqQRk
    \\0dwSOQKBgQD3halhZ454BobP6vGYnuxVB8Rw7raJ8GXvmm3Qn6ndMxaryABEhyPW
    \\m8rNPg2WxkJxJczyxSDIQSFJMAHoFrc03TDPtX2LXu3kzMS6eCtnMIdHccpWfrEd
    \\ICy7eM3dg9HFnasS6gkiT1rCrs9U5dwKfHxQHk7Y9YSm9cLagdeP+Q==
    \\-----END RSA PRIVATE KEY-----
;

pub const rsa_pkcs8 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDYkXyaobQMT9FQ
    \\fIJsKZIYVuKOUGBQqdVJg3OB6I1YXqy8GJXrbdgqdow7z68eP4Z/StOE7UACqMr2
    \\XkrSNg5wjJRB96hDZdnCIfOu90uU6xxAT0b/DM3TOx4aPTSVaCxnCfMFvNzMCCMK
    \\Za4XyIstuTEZ+GSs7wkyP+ENA+B3Q6SXp2nEnMV/EWEi0MQJX0RVGxCA4vL2tQMx
    \\INRP1cck9BS78d4youwCeifiSy9FRDYwmyzmbTtV51SaNHzt+WH9MtGaEsWxpK4a
    \\NNkbDbrIwBdZqlcla+VqD4f4bog1UB6vSHNcOIcqxHoh6mXewlvEFhriIt3pkKBe
    \\WegO/YkvAgMBAAECggEAZh1XcPv9Du8VxYsn3gNN8S8KnUr11yL1QDf8n0z9VKUz
    \\cm9vRTaifgcuwUcAjdUrQFsSWDOcAoT/SmKUigDWFyiaAW7ahokAP+LNaXsORtYD
    \\GKmo0rsBU++kln+0ixw3D5Cn59UxEP1nNFBUYb98LJ+NMO8n3UjKf8iR/5aL4P+E
    \\JrWDCXBziJt0P6hxAu8CQFN+4TnfesphT0nU/vWWYo8/a2VKU01L1v0Fis+RNOsk
    \\Jpp+kG7eMzDZmXGA26FxIXXb/KwdLqFbsP6MYNa1myW60YT6XO0j3CRNRrV1Pr39
    \\eYeXfh6rNupQ1Bqhd21bUM66PTH7y6pV9NXpJpRVzQKBgQD6RE1mXftVmar9Uirt
    \\RSoBQqRaNQ9AFcXKzoemFoopN2xChw+ejClFR2yzryIy9PZyrWBS7XPIgVQo/z71
    \\NWGbpHCqnURHmuB6RKJOyUdn4E/CYMWARBaT0ZrTXbZxuuEJnFqIs0HscajoUhFm
    \\5O6fBl/tyFItC5gxpG1yo7fAAwKBgQDdh474HSPRJ4FddLGUpUhCvftMQRNrqRpd
    \\UMgXurJi0lkvMHmJShlgk3zKq2YXUicGfWeeb/netYyoCdyBMi0bZBIhVUqTybE5
    \\c8oxFchXcNJnHOyk7RfK1+8EURCXHddtMM+DQ9SOksV9FtQfy0QjSKpREoGrmvHL
    \\tGUatH+YZQKBgQCi5/sJ+3szCUhIhUf0EuV41IxvO8KlkIajsTSTZHCiy7ToyUnd
    \\hpcGxat4ezPjv5j8pObilDad+bFyzlOJAip7Sdsc9CoSAjrE3BBbAKI+d8DzYlKt
    \\X6Tiq7oAhCvSdDcwLlqwSR9Mbd/o+iLhu3uogFnJSnBTagyzo7iquu9NSQKBgChy
    \\ndoTh/yiV+52Zg4b94uoIIAVybP4lkW/gClE/1knyvzgvvAgRW3qv/hJP0S2zUVU
    \\FF1LWLYfM+Vil45HWRENPnozloBRbThuOdaogYHlqaUGFPcwCw4QSyXgn0TYQANB
    \\zEHNWrwFdGWYi3aaqIBAvkg7Ns3cZpWpBGTR3BI5AoGBAPeFqWFnjngGhs/q8Zie
    \\7FUHxHDutonwZe+abdCfqd0zFqvIAESHI9abys0+DZbGQnElzPLFIMhBIUkwAegW
    \\tzTdMM+1fYte7eTMxLp4K2cwh0dxylZ+sR0gLLt4zd2D0cWdqxLqCSJPWsKuz1Tl
    \\3Ap8fFAeTtj1hKb1wtqB14/5
    \\-----END PRIVATE KEY-----
;

pub const rsa_pub =
    \\-----BEGIN PUBLIC KEY-----
    \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2JF8mqG0DE/RUHyCbCmS
    \\GFbijlBgUKnVSYNzgeiNWF6svBiV623YKnaMO8+vHj+Gf0rThO1AAqjK9l5K0jYO
    \\cIyUQfeoQ2XZwiHzrvdLlOscQE9G/wzN0zseGj00lWgsZwnzBbzczAgjCmWuF8iL
    \\LbkxGfhkrO8JMj/hDQPgd0Okl6dpxJzFfxFhItDECV9EVRsQgOLy9rUDMSDUT9XH
    \\JPQUu/HeMqLsAnon4ksvRUQ2MJss5m07VedUmjR87flh/TLRmhLFsaSuGjTZGw26
    \\yMAXWapXJWvlag+H+G6INVAer0hzXDiHKsR6Iepl3sJbxBYa4iLd6ZCgXlnoDv2J
    \\LwIDAQAB
    \\-----END PUBLIC KEY-----
;

/// Self-signed with `p256_sec1`, valid for 100 years from 2026-10-30.
pub const p256_cert =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBhDCCASugAwIBAgIUA/d+1cz1suALhOntfD4N5kZypykwCgYIKoZIzj0EAwIw
    \\FzEVMBMGA1UEAwwMaWV0cyB0ZXN0IENBMCAXDTI2MTAzMDEyNTQyMloYDzIxMjYx
    \\MDA2MTI1NDIyWjAXMRUwEwYDVQQDDAxpZXRzIHRlc3QgQ0EwWTATBgcqhkjOPQIB
    \\BggqhkjOPQMBBwNCAARXE6+Jak8vyfmfZEMiMqnWXM86ChHvcnsc6Ab+4kXexUkW
    \\qtuiadQg//sv9ztMoLSOd54lvjOOp4hDvIMT+Lxmo1MwUTAdBgNVHQ4EFgQUKC7g
    \\FGRkl92h9RyPFhP2G5T0nOkwHwYDVR0jBBgwFoAUKC7gFGRkl92h9RyPFhP2G5T0
    \\nOkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAIkPYZmbi0ZvNC
    \\X8Jv75HBTB3HFMTXDOjFiEW+vmSBKQIgPpqBV609Defk0MZRr3IRKqB57ZsuC7Dv
    \\oduY8KSK8Rc=
    \\-----END CERTIFICATE-----
;
