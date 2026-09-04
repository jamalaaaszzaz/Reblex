# Reblex
Iha hullu säännöt edelleen 1 ei tiivistelyjä placebo fake koodia keskeneräidtä koodia! 2 vain oikeaa parasta kunnolla mietitty parasta aito koodia joka varmasti toimii eikp ole leikkikoodia

## MorphLabFE.lua

FE-skripti, joka muuttaa oman hahmosi. Ei luo uusia parteja.

### FE-replikointi (vahvistettu DevForum-tutkimuksella)
- C0/C1/CFrame EIVAT replikoidu (vain fysiikka: position/velocity replikoituu)
- Humanoidin Animatoriin ladatut ANIMAATIOT replikoituvat kaikille automaattisesti
- Siksi HELI ja MONSTER kayttavat julkaistuja emote-animaatioita -> nakyvat kaikille
- BUNNY/DOG: ei julkaistua assetia -> lokaali joint-pose (nakyy omalla ruudulla)

### Animaatiot (loopissa koko ajan kun moodi paalla)
- HELI = "Helicopter" emote (110553756436163) - replikoituu kaikille
- MONSTER = "Pain of Pains" emote (132985306809464) - replikoituu kaikille
- Muokkaus: animspeed skaalautuu liikenopeuteen (AdjustSpeed)

### Lento (todistettu FE-drone-kaava, ei flingia)
- BodyVelocity + yaw-only BodyGyro (P=9000)
- Raajoja ei siirreta kauas jointeista (se aiheutti flingin)
- ASCEND/DESCEND-napit hypynapin viereen (PC: SPACE/CTRL)
- Lattia-raycast: laskeutuminen pysahtyy maahan

### GUI (englanniksi, ei emojeita)
- Lapinakyva, raahattava, pienennettava (-), suljettava (X, RightShift avaa)
- Moodipillit, ENABLE/DISABLE, SPECIAL-efekti, statusrivi (nayttaa ANIM/LOCAL)
