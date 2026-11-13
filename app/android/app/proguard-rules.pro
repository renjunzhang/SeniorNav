# Baidu Search 9.0.0 + base/common contain JNI FindClass/RegisterNatives and
# reflection calls that R8 cannot infer. Their bundled consumer rules are empty.
# In particular libBaiduMapSDK_base_v9_0_0.so resolves ParcelItem and
# URLEncodeUtils by their original names; removing either can abort initialization.
# Include the SDK's bundled mshield/xclient security classes, whose native code
# also resolves Java classes/methods by name. Do not disable R8 for the app.
-keep class com.baidu.** { *; }
