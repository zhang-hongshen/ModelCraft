cd ./ModelCraft/Executables
cp -f $(which ollama) ./
./ollama --version
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "ollama.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.inherit bool true" ollama.entitlements

codesign -s - -i com.zhanghongshen.ModelCraft.ollama -o runtime --entitlements ollama.entitlements -f ollama
rm ./ollama.entitlements
