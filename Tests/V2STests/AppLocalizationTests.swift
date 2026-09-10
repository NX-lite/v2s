import Testing
@testable import v2s

@Suite struct AppLocalizationTests {
    @Test func everyInterfaceLanguageDefinesEveryAssistantStringDirectly() {
        for language in LanguageCatalog.interface {
            for key in AppLocalization.assistantTextKeys {
                #expect(
                    AppLocalization.hasLocalizedString(key, languageID: language.id),
                    "\(language.id) is missing \(key.rawValue)"
                )
            }
        }
    }

    @Test func assistantSemanticTextUsesLocalizedLabelsAndPreservesProviderDetail() {
        #expect(AppLocalization.assistantActionTitle(.followUp, languageID: "en") == "Follow Up")
        #expect(AppLocalization.assistantActionTitle(.ask, languageID: "zh-Hans") == "提问")
        #expect(
            AppLocalization.assistantFailureText(.invalidConfiguration, languageID: "en")
                == "Complete the API key, base URL, and model before continuing."
        )
        #expect(
            AppLocalization.assistantFailureText(.invalidConfiguration, languageID: "zh-Hans")
                == "请先填写 API 密钥、基础 URL 和模型。"
        )

        let providerDetail = "Provider says no image support"
        #expect(
            AppLocalization.assistantFailureText(
                .requestFailed(detail: providerDetail),
                languageID: "en"
            ) == "Assistant request failed: \(providerDetail)"
        )
        #expect(
            AppLocalization.assistantFailureText(
                .requestFailed(detail: providerDetail),
                languageID: "zh-Hans"
            ) == "助手请求失败：\(providerDetail)"
        )
        #expect(
            AppLocalization.assistantFailureText(.requestFailed(detail: nil), languageID: "en")
                == "Assistant request failed."
        )
    }

    @Test func assistantReplyScreenAndHotKeySemanticTextRemainLocalized() {
        #expect(
            AppLocalization.assistantReplyText(.thinking, languageID: "en") == "Thinking…"
        )
        #expect(
            AppLocalization.assistantReplyText(.thinking, languageID: "zh-Hans") == "思考中…"
        )
        #expect(
            AppLocalization.assistantReplyText(.response("Provider response"), languageID: "zh-Hans")
                == "Provider response"
        )
        #expect(
            AppLocalization.screenContextWarning(.permissionNeeded, languageID: "en")
                == "Screen Recording permission is needed to include the current screen."
        )
        #expect(
            AppLocalization.screenContextWarning(.ocrFailed, languageID: "zh-Hans")
                == "已发送当前屏幕，但无法识别其中的文字。"
        )
        #expect(AppLocalization.screenContextWarning(.ready, languageID: "en") == nil)
        #expect(
            AppLocalization.hotKeyRegistrationErrorText(.duplicateBinding, languageID: "zh-Hans")
                == "此快捷键已被另一项助手操作使用。"
        )
        #expect(
            AppLocalization.hotKeyRegistrationErrorText(
                .registrationFailed(-9876),
                languageID: "en"
            ) == "Couldn't register this hotkey (OSStatus -9876)."
        )
    }

    @Test func englishMultipleSourcesUsesSingularAndPluralForms() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "en") == "1 Source")
        #expect(AppLocalization.multipleSourcesText(count: 3, languageID: "en") == "3 Sources")
    }

    @Test func russianMultipleSourcesUsesProperPluralCategories() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "ru") == "1 источник")
        #expect(AppLocalization.multipleSourcesText(count: 2, languageID: "ru") == "2 источника")
        #expect(AppLocalization.multipleSourcesText(count: 5, languageID: "ru") == "5 источников")
        #expect(AppLocalization.multipleSourcesText(count: 11, languageID: "ru") == "11 источников")
        #expect(AppLocalization.multipleSourcesText(count: 21, languageID: "ru") == "21 источник")
    }

    @Test func arabicMultipleSourcesUsesDistinctPluralForms() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "ar") == "مصدر واحد")
        #expect(AppLocalization.multipleSourcesText(count: 2, languageID: "ar") == "مصدران")
        #expect(AppLocalization.multipleSourcesText(count: 4, languageID: "ar") == "4 مصادر")
        #expect(AppLocalization.multipleSourcesText(count: 12, languageID: "ar") == "12 مصدرًا")
    }
}
