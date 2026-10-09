package com.outland.game

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.google.android.libraries.ads.mobile.sdk.MobileAds
import com.google.android.libraries.ads.mobile.sdk.banner.AdSize
import com.google.android.libraries.ads.mobile.sdk.banner.AdView
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAd
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAdRequest
import com.google.android.libraries.ads.mobile.sdk.common.AdLoadCallback
import com.google.android.libraries.ads.mobile.sdk.common.AdRequest
import com.google.android.libraries.ads.mobile.sdk.common.LoadAdError
import com.google.android.libraries.ads.mobile.sdk.initialization.InitializationConfig
import com.google.android.libraries.ads.mobile.sdk.interstitial.InterstitialAd
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private lateinit var gameView: WebView
    private lateinit var bannerContainer: FrameLayout
    private var bannerAd: AdView? = null
    private var interstitialAd: InterstitialAd? = null
    private var interstitialLoading = false
    private var adsInitialized = false
    private val gameUri by lazy { Uri.parse(BuildConfig.GAME_URL) }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(20, 26, 23)
        window.navigationBarColor = Color.rgb(20, 26, 23)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(20, 26, 23))
        }
        gameView = WebView(this).apply {
            setBackgroundColor(Color.rgb(20, 26, 23))
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            addJavascriptInterface(GameAdBridge(), "OutlandAdBridge")
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val uri = request.url
                    if (uri.host == gameUri.host && uri.scheme == "https") return false
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    return true
                }
            }
        }
        root.addView(gameView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        bannerContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(20, 26, 23))
            visibility = View.GONE
        }
        root.addView(bannerContainer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(root)

        if (BuildConfig.GAME_URL.contains("YOUR_PUBLIC_GAME_HOST")) {
            showSetupMessage()
        } else {
            gameView.loadUrl(BuildConfig.GAME_URL)
        }

        thread(name = "admob-init") {
            MobileAds.initialize(
                applicationContext,
                InitializationConfig.Builder(BuildConfig.ADMOB_APP_ID).build()
            ) {
                runOnUiThread {
                    adsInitialized = true
                    loadBanner()
                    loadInterstitial()
                }
            }
        }
    }

    private fun showSetupMessage() {
        val message = """<!doctype html><html><meta name="viewport" content="width=device-width, initial-scale=1"><body style="margin:0;background:#141a17;color:#edf0e6;font:16px sans-serif;display:grid;place-items:center;min-height:100vh;padding:24px;box-sizing:border-box;text-align:center"><div><h2>Game server not configured</h2><p>Set GAME_URL in android/gradle.properties to your public HTTPS game server.</p></div></body></html>"""
        gameView.loadDataWithBaseURL(null, message, "text/html", "UTF-8", null)
    }

    private fun loadBanner() {
        if (bannerAd != null) return
        val widthDp = (resources.displayMetrics.widthPixels / resources.displayMetrics.density).toInt()
        val adSize = AdSize.getLargeAnchoredAdaptiveBannerAdSize(this, widthDp)
        val adView = AdView(this)
        bannerAd = adView
        bannerContainer.addView(adView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        val request = BannerAdRequest.Builder(BuildConfig.BANNER_AD_UNIT_ID, adSize).build()
        adView.loadAd(request, object : AdLoadCallback<BannerAd>() {
            override fun onAdLoaded(ad: BannerAd) {
                bannerContainer.visibility = View.VISIBLE
            }

            override fun onAdFailedToLoad(adError: LoadAdError) {
                bannerContainer.visibility = View.GONE
            }
        })
    }

    private fun loadInterstitial() {
        if (!adsInitialized || interstitialAd != null || interstitialLoading) return
        interstitialLoading = true
        InterstitialAd.load(
            AdRequest.Builder(BuildConfig.INTERSTITIAL_AD_UNIT_ID).build(),
            object : AdLoadCallback<InterstitialAd>() {
                override fun onAdLoaded(ad: InterstitialAd) {
                    interstitialLoading = false
                    interstitialAd = ad
                }

                override fun onAdFailedToLoad(adError: LoadAdError) {
                    interstitialLoading = false
                    interstitialAd = null
                }
            }
        )
    }

    private fun showMatchInterstitial() {
        val ad = interstitialAd ?: return
        interstitialAd = null
        ad.setImmersiveMode(true)
        ad.show(this)
        loadInterstitial()
    }

    private inner class GameAdBridge {
        @JavascriptInterface
        fun onMatchEnded() {
            runOnUiThread { showMatchInterstitial() }
        }
    }

    override fun onResume() {
        super.onResume()
        if (adsInitialized) loadInterstitial()
    }

    override fun onBackPressed() {
        if (::gameView.isInitialized && gameView.canGoBack()) gameView.goBack() else super.onBackPressed()
    }

    override fun onDestroy() {
        bannerAd?.destroy()
        bannerAd = null
        if (::gameView.isInitialized) {
            gameView.removeJavascriptInterface("OutlandAdBridge")
            gameView.destroy()
        }
        super.onDestroy()
    }
}
