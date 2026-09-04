# Reblex
Iha hullu säännöt edelleen 1 ei tiivistelyjä placebo fake koodia keskeneräidtä koodia! 2 vain oikeaa parasta kunnolla mietitty parasta aito koodia joka varmasti toimii eikp ole leikkikoodia

## MorphLabFE.lua

FE-skripti, joka muuttaa oman hahmosi neljaksi eri olennoksi. Ei luo uusia parteja (100% FE, kaikki pelaajat nakevat).

### Tekniikka (sama kuin Robloxin animaatioissa)
1. Motor6D-liitosten C0-arvot asetetaan poseen. Luajan omistamat liitokset replikoituvat automaattisesti.
2. Fysiikan solveri sijoittaa osat itse liitosten mukaan -> ei fysiikkataistelua, ei flingia.
3. Lentoon BodyVelocity + yaw-only BodyGyro (sama kaava kuin toimivassa FE-drone-referenssissa).
4. Jointit nollataan ensin kun moodi vaihtuu / skripti kaynnistyy, pose otetaan kayttoon seuraavassa framessa.

### Moodit
- HELICOPTER: runko makuulle (root-joint), paa=ohjaamo, o.kasi=masto, o.jalka=paapotkuri (pyorii), v.kasi=hantapuomi, v.jalka=hantapotkuri. Special: CRASHOUT.
- BUNNY: kadet=jousitetut korvat, jalat=potkujalat, pomppufysiikka squash & stretch. Special: THUMP.
- DOG: neljajalkainen vaakatasossa, vinottainen rava-askel, lorskahdus. Special: BOW.
- MONSTER: kumartunut keinuva hahmo, pitkat kadet. Special: ROAR.

### Ohjaus
- WASD / joystick = ohjaa suuntaa (leijuu paikallaan ilman inputtia)
- ASCEND / DESCEND -napit hypynapin viereen (PC:lla SPACE / CTRL)
- Lattia-raycast: laskeutuminen pysahtyy maahan

### GUI (englanniksi, ei emojeita)
- Lapinakyva, raahattava, pienennettava (-), suljettava (X, RightShift avaa)
- Moodipillit, ENABLE/DISABLE, SPECIAL-efekti, statusrivi
