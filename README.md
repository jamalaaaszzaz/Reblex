# Reblex
Iha hullu säännöt edelleen 1 ei tiivistelyjä placebo fake koodia keskeneräidtä koodia! 2 vain oikeaa parasta kunnolla mietitty parasta aito koodia joka varmasti toimii eikp ole leikkikoodia

## MorphLabFE.lua

FE-skripti, joka muuttaa oman hahmosi neljaksi eri olennoksi. Ei luo uusia parteja - raajat asetetaan uusiin paikkoihin joka frame, joten kaikki pelaajat nakevat sen (100% FE). Toimii R6:lla (ensisijainen) ja R15:lla (varavirta raajaketjuilla).

### Moodit
- HELICOPTER: runko makuulla, paa=ohjaamo, o.kasi=masto selasta ylos, o.jalka=paapotkuri, v.kasi=hantapuomi, v.jalka=hantapotkuri. ASCEND=nousu (paapotkuri kihahtaa), DESCEND=lasku (potkurit hiljenevat), eteenpain=nokka kallistuu + hantapotkuri kiihtyy. Special: CRASHOUT.
- BUNNY: kadet=korvat jousitettuina (reagoivat kiihtyvyyteen), jalat=potkujalat, pomppufysiikka squash & stretch -efektilla. HOP=iso pomppu, DUCK=kyykky. Special: THUMP.
- DOG: neljajalkainen, vinottainen rava-askel. LEAP=karkaus, SIT=istuminen. Special: BOW.
- MONSTER: raskas keinuva hahmo, pitkat kadet. POUND=iskema, CROUCH=kuperkeikko. Special: ROAR.

### Ohjaus
- WASD / joystick = ohjaa suuntaa (leijuu paikallaan ilman inputtia)
- ASCEND- ja DESCEND-napit ilmestyvat hypynapin viereen (PC:lla myos SPACE / CTRL)
- Lattia-raycast estaa maan lapi uppoamisen - laskeutuminen pysahtyy maahan

### GUI (englanniksi, ei emojeita)
- Lapinakyva, raahattava, pienennettava (-), suljettava (X, RightShift avaa)
- Moodivalinnat pill-painikkeina, ENABLE/DISABLE, SPECIAL-efekti
- Reaaliaikainen status: moodi, nopeus, rotori/hop %
