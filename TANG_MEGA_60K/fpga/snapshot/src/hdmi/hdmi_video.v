// Original procedural 720p instrument dashboard. No framebuffer/font BSRAM.
// Pipeline: raster/address -> synchronous scope RAM -> registered RGB/sync.
module hdmi_video #(parameter TEST_SOURCE=0)(input wire clk,rst_n,lr_pixel,delay_pixel,
 input wire [15:0] wave_data,input wire front_valid,mono,
 input wire [24:0] keys,input wire [5:0] voices,input wire [1:0] instrument,
 input wire [7:0] velocity,input wire [1:0] effect,
 output wire [14:0] xy_addr,output wire [7:0] wave_addr,output wire frame,
 output reg [23:0] rgb,output reg hs,vs,de,
 output wire [5:0] spectrum_addr,input wire [7:0] spectrum_level,input wire spectrum_ready);
 reg [10:0] h,h1;
 reg [5:0] spectrum_band;
 reg [4:0] spectrum_subx,spectrum_subx1;
 assign spectrum_addr=spectrum_band;
 // 64 bars x 18 pixels. A counter replaces a wide divide on the pixel path.
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin spectrum_band<=0;spectrum_subx<=0;spectrum_subx1<=0;end
 else begin
   spectrum_subx1<=spectrum_subx;
   if(h==47)begin spectrum_band<=0;spectrum_subx<=0;end
   else if(h>=48 && h<1200)begin
     if(spectrum_subx==17)begin spectrum_subx<=0;spectrum_band<=spectrum_band+1'b1;end
     else spectrum_subx<=spectrum_subx+1'b1;
   end
 end
 reg [9:0] v,v1;
 reg hs1,vs1,de1;
 reg [23:0] color;
 reg [23:0] base2,base3,text_color2,text_color3;
 reg [7:0] ch2;
 reg [2:0] gx2,gy2;
 reg text_region2,text3,hs2,vs2,de2,hs3,vs3,de3;
 reg [2:0] text_row;
 reg [7:0] ch;
 reg text_region;
 wire [10:0] text_x=h1-11'd48;
 wire [6:0] text_col=text_x[10:4];
 wire [2:0] gx=text_x[3:1],gy=v1[3:1];
 wire [34:0] glyph2=glyph(ch2);
 wire [10:0] local_x=(h>=928)?h-11'd944:h-11'd624;
 wire [9:0] local_y=v-10'd176;
 wire [10:0] wave_x=h-11'd48;
 assign xy_addr={1'b0,local_y[7:1],local_x[7:1]};
 assign wave_addr=wave_x[8:1];
 assign frame=(h==0 && v==720);
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
   h<=0;v<=0;h1<=0;v1<=0;hs1<=0;vs1<=0;de1<=0;rgb<=0;hs<=0;vs<=0;de<=0;
   base2<=0;base3<=0;text_color2<=0;text_color3<=0;ch2<=0;gx2<=0;gy2<=0;
   text_region2<=0;text3<=0;hs2<=0;vs2<=0;de2<=0;hs3<=0;vs3<=0;de3<=0;
 end
 else begin
   if(h==1649) begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end
   else h<=h+1'b1;
   h1<=h;v1<=v;de1<=(h<1280 && v<720);
   hs1<=(h>=1390 && h<1430);vs1<=(v>=725 && v<730);
   // Separate text layout/status decode from font lookup and glyph indexing.
   base2<=color;ch2<=ch;gx2<=gx;gy2<=gy;text_region2<=text_region;
   text_color2<=(text_row==0)?24'he7eef9:(text_row==2)?24'h83b5db:24'h9bb2d0;
   hs2<=hs1;vs2<=vs1;de2<=de1;
   base3<=base2;text_color3<=text_color2;
   text3<=text_region2 && gx2<5 && gy2<7 && glyph2[34-gy2*5-gx2];
   hs3<=hs2;vs3<=vs2;de3<=de2;
   rgb<=de3?(text3?text_color3:base3):24'd0;de<=de3;hs<=hs3;vs<=vs3;
 end
 // Font is a combinational 5x7 case table, with 16x16 text cells.
 function [34:0] glyph(input [7:0] c);
 begin case(c)
  8'd48:glyph=35'b01110100011001110101110011000101110;
  8'd49:glyph=35'b00100011000010000100001000010001110;
  8'd50:glyph=35'b01110100010000100010001000100011111;
  8'd51:glyph=35'b11110000010000101110000010000111110;
  8'd52:glyph=35'b00010001100101010010111110001000010;
  8'd53:glyph=35'b11111100001000011110000010000111110;
  8'd54:glyph=35'b01110100001000011110100011000101110;
  8'd55:glyph=35'b11111000010001000100010000100001000;
  8'd56:glyph=35'b01110100011000101110100011000101110;
  8'd57:glyph=35'b01110100011000101111000010000101110;
  8'd65:glyph=35'b01110100011000111111100011000110001;
  8'd66:glyph=35'b11110100011000111110100011000111110;
  8'd67:glyph=35'b01111100001000010000100001000001111;
  8'd68:glyph=35'b11110100011000110001100011000111110;
  8'd69:glyph=35'b11111100001000011110100001000011111;
  8'd70:glyph=35'b11111100001000011110100001000010000;
  8'd71:glyph=35'b01111100001000010111100011000101111;
  8'd72:glyph=35'b10001100011000111111100011000110001;
  8'd73:glyph=35'b11111001000010000100001000010011111;
  8'd74:glyph=35'b00111000100001000010100101001001100;
  8'd75:glyph=35'b10001100101010011000101001001010001;
  8'd76:glyph=35'b10000100001000010000100001000011111;
  8'd77:glyph=35'b10001110111010110101100011000110001;
  8'd78:glyph=35'b10001110011010110011100011000110001;
  8'd79:glyph=35'b01110100011000110001100011000101110;
  8'd80:glyph=35'b11110100011000111110100001000010000;
  8'd81:glyph=35'b01110100011000110001101011001001101;
  8'd82:glyph=35'b11110100011000111110101001001010001;
  8'd83:glyph=35'b01111100001000001110000010000111110;
  8'd84:glyph=35'b11111001000010000100001000010000100;
  8'd85:glyph=35'b10001100011000110001100011000101110;
  8'd86:glyph=35'b10001100011000110001100010101000100;
  8'd87:glyph=35'b10001100011000110101101011010101010;
  8'd88:glyph=35'b10001100010101000100010101000110001;
  8'd89:glyph=35'b10001100010101000100001000010000100;
  8'd90:glyph=35'b11111000010001000100010001000011111;
  8'd47:glyph=35'b00001000100001000100010000100010000;
  8'd124:glyph=35'b00100001000010000100001000010000100;
  8'd45:glyph=35'b00000000000000011111000000000000000;
  8'd43:glyph=35'b00000001000010011111001000010000000;
  default:glyph=0;
 endcase end endfunction
 function [7:0] label_char(input [2:0] row,input [6:0] col);
 begin case({row,col})
  10'd0:label_char=8'd77;
  10'd1:label_char=8'd69;
  10'd2:label_char=8'd71;
  10'd3:label_char=8'd65;
  10'd5:label_char=8'd54;
  10'd6:label_char=8'd48;
  10'd7:label_char=8'd75;
  10'd9:label_char=8'd124;
  10'd11:label_char=8'd82;
  10'd12:label_char=8'd69;
  10'd13:label_char=8'd65;
  10'd14:label_char=8'd76;
  10'd15:label_char=8'd73;
  10'd16:label_char=8'd83;
  10'd17:label_char=8'd84;
  10'd18:label_char=8'd73;
  10'd19:label_char=8'd67;
  10'd21:label_char=8'd83;
  10'd22:label_char=8'd89;
  10'd23:label_char=8'd78;
  10'd24:label_char=8'd84;
  10'd25:label_char=8'd72;
  10'd128:label_char=8'd51;
  10'd129:label_char=8'd50;
  10'd131:label_char=8'd86;
  10'd132:label_char=8'd79;
  10'd133:label_char=8'd73;
  10'd134:label_char=8'd67;
  10'd135:label_char=8'd69;
  10'd136:label_char=8'd83;
  10'd138:label_char=8'd47;
  10'd140:label_char=8'd80;
  10'd141:label_char=8'd84;
  10'd142:label_char=8'd56;
  10'd143:label_char=8'd50;
  10'd144:label_char=8'd49;
  10'd145:label_char=8'd49;
  10'd147:label_char=8'd47;
  10'd149:label_char=8'd76;
  10'd150:label_char=8'd73;
  10'd151:label_char=8'd86;
  10'd152:label_char=8'd69;
  10'd154:label_char=8'd65;
  10'd155:label_char=8'd85;
  10'd156:label_char=8'd68;
  10'd157:label_char=8'd73;
  10'd158:label_char=8'd79;
  10'd256:label_char=8'd76;
  10'd257:label_char=8'd69;
  10'd258:label_char=8'd70;
  10'd259:label_char=8'd84;
  10'd261:label_char=8'd43;
  10'd263:label_char=8'd82;
  10'd264:label_char=8'd73;
  10'd265:label_char=8'd71;
  10'd266:label_char=8'd72;
  10'd267:label_char=8'd84;
  10'd269:label_char=8'd87;
  10'd270:label_char=8'd65;
  10'd271:label_char=8'd86;
  10'd272:label_char=8'd69;
  10'd292:label_char=8'd65;
  10'd293:label_char=8'd67;
  10'd294:label_char=8'd84;
  10'd295:label_char=8'd85;
  10'd296:label_char=8'd65;
  10'd297:label_char=8'd76;
  10'd299:label_char=8'd76;
  10'd300:label_char=8'd47;
  10'd301:label_char=8'd82;
  10'd312:label_char=8'd76;
  10'd314:label_char=8'd47;
  10'd316:label_char=8'd76;
  10'd318:label_char=8'd68;
  10'd319:label_char=8'd69;
  10'd320:label_char=8'd76;
  10'd321:label_char=8'd65;
  10'd322:label_char=8'd89;
  10'd323:label_char=8'd56;
  10'd384:label_char=8'd86;
  10'd385:label_char=8'd79;
  10'd386:label_char=8'd73;
  10'd387:label_char=8'd67;
  10'd388:label_char=8'd69;
  10'd389:label_char=8'd83;
  10'd391:label_char=8'd48;
  10'd392:label_char=8'd48;
  10'd393:label_char=8'd47;
  10'd394:label_char=8'd51;
  10'd395:label_char=8'd50;
  10'd400:label_char=8'd82;
  10'd401:label_char=8'd72;
  10'd402:label_char=8'd79;
  10'd403:label_char=8'd68;
  10'd404:label_char=8'd69;
  10'd405:label_char=8'd83;
  10'd407:label_char=8'd69;
  10'd408:label_char=8'd80;
  10'd416:label_char=8'd86;
  10'd417:label_char=8'd69;
  10'd418:label_char=8'd76;
  10'd420:label_char=8'd72;
  10'd421:label_char=8'd69;
  10'd422:label_char=8'd88;
  10'd424:label_char=8'd48;
  10'd425:label_char=8'd48;
  10'd432:label_char=8'd70;
  10'd433:label_char=8'd88;
  10'd435:label_char=8'd48;
  10'd440:label_char=8'd76;
  10'd441:label_char=8'd47;
  10'd442:label_char=8'd82;
  10'd444:label_char=8'd77;
  10'd445:label_char=8'd79;
  10'd446:label_char=8'd78;
  10'd447:label_char=8'd79;
  10'd512:label_char=8'd80;
  10'd513:label_char=8'd82;
  10'd514:label_char=8'd69;
  10'd515:label_char=8'd83;
  10'd516:label_char=8'd83;
  10'd517:label_char=8'd69;
  10'd518:label_char=8'd68;
  10'd520:label_char=8'd75;
  10'd521:label_char=8'd69;
  10'd522:label_char=8'd89;
  10'd523:label_char=8'd83;
  10'd525:label_char=8'd47;
  10'd527:label_char=8'd67;
  10'd528:label_char=8'd52;
  10'd530:label_char=8'd84;
  10'd531:label_char=8'd79;
  10'd533:label_char=8'd67;
  10'd534:label_char=8'd54;
  10'd640:label_char=8'd76;
  10'd641:label_char=8'd73;
  10'd642:label_char=8'd86;
  10'd643:label_char=8'd69;
  10'd645:label_char=8'd68;
  10'd646:label_char=8'd65;
  10'd647:label_char=8'd67;
  10'd649:label_char=8'd124;
  10'd651:label_char=8'd86;
  10'd652:label_char=8'd73;
  10'd653:label_char=8'd69;
  10'd654:label_char=8'd87;
  10'd656:label_char=8'd71;
  10'd657:label_char=8'd65;
  10'd658:label_char=8'd73;
  10'd659:label_char=8'd78;
  10'd661:label_char=8'd88;
  10'd662:label_char=8'd52;
  10'd664:label_char=8'd124;
  10'd666:label_char=8'd68;
  10'd667:label_char=8'd69;
  10'd668:label_char=8'd76;
  10'd669:label_char=8'd65;
  10'd670:label_char=8'd89;
  10'd672:label_char=8'd61;
  10'd674:label_char=8'd56;
  10'd676:label_char=8'd68;
  10'd677:label_char=8'd65;
  10'd678:label_char=8'd67;
  10'd680:label_char=8'd83;
  10'd681:label_char=8'd65;
  10'd682:label_char=8'd77;
  10'd683:label_char=8'd80;
  10'd684:label_char=8'd76;
  10'd685:label_char=8'd69;
  10'd686:label_char=8'd83;
  default:label_char=8'd32;
 endcase end endfunction

 function [7:0] extra_label(input [2:0] row,input [6:0] col);
 begin case({row,col})
  10'd0:extra_label=8'd77;
  10'd1:extra_label=8'd69;
  10'd2:extra_label=8'd71;
  10'd3:extra_label=8'd65;
  10'd5:extra_label=8'd54;
  10'd6:extra_label=8'd48;
  10'd7:extra_label=8'd75;
  10'd9:extra_label=8'd47;
  10'd11:extra_label=8'd77;
  10'd12:extra_label=8'd65;
  10'd13:extra_label=8'd73;
  10'd14:extra_label=8'd78;
  10'd16:extra_label=8'd89;
  10'd18:extra_label=8'd47;
  10'd20:extra_label=8'd83;
  10'd21:extra_label=8'd84;
  10'd22:extra_label=8'd69;
  10'd23:extra_label=8'd82;
  10'd24:extra_label=8'd69;
  10'd25:extra_label=8'd79;
  10'd27:extra_label=8'd43;
  10'd29:extra_label=8'd70;
  10'd30:extra_label=8'd70;
  10'd31:extra_label=8'd84;
  10'd640:extra_label=8'd76;
  10'd641:extra_label=8'd73;
  10'd642:extra_label=8'd86;
  10'd643:extra_label=8'd69;
  10'd645:extra_label=8'd68;
  10'd646:extra_label=8'd65;
  10'd647:extra_label=8'd67;
  10'd649:extra_label=8'd47;
  10'd651:extra_label=8'd86;
  10'd652:extra_label=8'd73;
  10'd653:extra_label=8'd69;
  10'd654:extra_label=8'd87;
  10'd656:extra_label=8'd71;
  10'd657:extra_label=8'd65;
  10'd658:extra_label=8'd73;
  10'd659:extra_label=8'd78;
  10'd661:extra_label=8'd88;
  10'd662:extra_label=8'd49;
  10'd664:extra_label=8'd47;
  10'd666:extra_label=8'd68;
  10'd667:extra_label=8'd69;
  10'd668:extra_label=8'd76;
  10'd669:extra_label=8'd65;
  10'd670:extra_label=8'd89;
  10'd672:extra_label=8'd56;
  10'd674:extra_label=8'd68;
  10'd675:extra_label=8'd65;
  10'd676:extra_label=8'd67;
  10'd678:extra_label=8'd83;
  10'd679:extra_label=8'd65;
  10'd680:extra_label=8'd77;
  10'd681:extra_label=8'd80;
  10'd682:extra_label=8'd76;
  10'd683:extra_label=8'd69;
  10'd684:extra_label=8'd83;
  10'd686:extra_label=8'd47;
  10'd688:extra_label=8'd77;
  10'd689:extra_label=8'd65;
  10'd690:extra_label=8'd73;
  10'd691:extra_label=8'd78;
  10'd693:extra_label=8'd89;
  10'd695:extra_label=8'd65;
  10'd696:extra_label=8'd85;
  10'd697:extra_label=8'd68;
  10'd698:extra_label=8'd73;
  10'd699:extra_label=8'd79;
  10'd768:extra_label=8'd70;
  10'd769:extra_label=8'd70;
  10'd770:extra_label=8'd84;
  10'd772:extra_label=8'd49;
  10'd773:extra_label=8'd48;
  10'd774:extra_label=8'd50;
  10'd775:extra_label=8'd52;
  10'd777:extra_label=8'd47;
  10'd779:extra_label=8'd72;
  10'd780:extra_label=8'd65;
  10'd781:extra_label=8'd78;
  10'd782:extra_label=8'd78;
  10'd784:extra_label=8'd47;
  10'd786:extra_label=8'd54;
  10'd787:extra_label=8'd52;
  10'd789:extra_label=8'd66;
  10'd790:extra_label=8'd65;
  10'd791:extra_label=8'd78;
  10'd792:extra_label=8'd68;
  10'd793:extra_label=8'd83;
  10'd795:extra_label=8'd47;
  10'd797:extra_label=8'd77;
  10'd798:extra_label=8'd79;
  10'd799:extra_label=8'd78;
  10'd800:extra_label=8'd79;
  10'd802:extra_label=8'd70;
  10'd803:extra_label=8'd79;
  10'd804:extra_label=8'd76;
  10'd805:extra_label=8'd68;
  10'd807:extra_label=8'd47;
  10'd809:extra_label=8'd82;
  10'd810:extra_label=8'd69;
  10'd811:extra_label=8'd76;
  10'd812:extra_label=8'd65;
  10'd813:extra_label=8'd84;
  10'd814:extra_label=8'd73;
  10'd815:extra_label=8'd86;
  10'd816:extra_label=8'd69;
  10'd818:extra_label=8'd76;
  10'd819:extra_label=8'd69;
  10'd820:extra_label=8'd86;
  10'd821:extra_label=8'd69;
  10'd822:extra_label=8'd76;
  10'd896:extra_label=8'd53;
  10'd897:extra_label=8'd48;
  10'd899:extra_label=8'd72;
  10'd900:extra_label=8'd90;
  10'd914:extra_label=8'd56;
  10'd915:extra_label=8'd48;
  10'd916:extra_label=8'd48;
  10'd918:extra_label=8'd72;
  10'd919:extra_label=8'd90;
  10'd932:extra_label=8'd50;
  10'd933:extra_label=8'd75;
  10'd934:extra_label=8'd52;
  10'd936:extra_label=8'd72;
  10'd937:extra_label=8'd90;
  10'd950:extra_label=8'd53;
  10'd951:extra_label=8'd75;
  10'd952:extra_label=8'd53;
  10'd954:extra_label=8'd72;
  10'd955:extra_label=8'd90;
  10'd964:extra_label=8'd49;
  10'd965:extra_label=8'd50;
  10'd967:extra_label=8'd75;
  10'd968:extra_label=8'd72;
  10'd969:extra_label=8'd90;
  default:extra_label=8'd32;
 endcase end endfunction

 function [7:0] hex_char(input [3:0] z);
 begin hex_char=z<10?8'd48+z:8'd65+z-10;end endfunction
 function [7:0] demo_char(input [2:0] row,input [6:0] col);
 begin case({row,col})
  10'd0:demo_char=8'd77;
  10'd1:demo_char=8'd69;
  10'd2:demo_char=8'd71;
  10'd3:demo_char=8'd65;
  10'd5:demo_char=8'd54;
  10'd6:demo_char=8'd48;
  10'd7:demo_char=8'd75;
  10'd9:demo_char=8'd124;
  10'd11:demo_char=8'd72;
  10'd12:demo_char=8'd68;
  10'd13:demo_char=8'd77;
  10'd14:demo_char=8'd73;
  10'd16:demo_char=8'd83;
  10'd17:demo_char=8'd69;
  10'd18:demo_char=8'd76;
  10'd19:demo_char=8'd70;
  10'd21:demo_char=8'd84;
  10'd22:demo_char=8'd69;
  10'd23:demo_char=8'd83;
  10'd24:demo_char=8'd84;
  10'd128:demo_char=8'd55;
  10'd129:demo_char=8'd50;
  10'd130:demo_char=8'd48;
  10'd131:demo_char=8'd80;
  10'd133:demo_char=8'd47;
  10'd135:demo_char=8'd71;
  10'd136:demo_char=8'd69;
  10'd137:demo_char=8'd78;
  10'd138:demo_char=8'd69;
  10'd139:demo_char=8'd82;
  10'd140:demo_char=8'd65;
  10'd141:demo_char=8'd84;
  10'd142:demo_char=8'd69;
  10'd143:demo_char=8'd68;
  10'd145:demo_char=8'd84;
  10'd146:demo_char=8'd69;
  10'd147:demo_char=8'd83;
  10'd148:demo_char=8'd84;
  10'd150:demo_char=8'd83;
  10'd151:demo_char=8'd73;
  10'd152:demo_char=8'd71;
  10'd153:demo_char=8'd78;
  10'd154:demo_char=8'd65;
  10'd155:demo_char=8'd76;
  10'd256:demo_char=8'd76;
  10'd257:demo_char=8'd69;
  10'd258:demo_char=8'd70;
  10'd259:demo_char=8'd84;
  10'd261:demo_char=8'd43;
  10'd263:demo_char=8'd82;
  10'd264:demo_char=8'd73;
  10'd265:demo_char=8'd71;
  10'd266:demo_char=8'd72;
  10'd267:demo_char=8'd84;
  10'd269:demo_char=8'd87;
  10'd270:demo_char=8'd65;
  10'd271:demo_char=8'd86;
  10'd272:demo_char=8'd69;
  10'd292:demo_char=8'd84;
  10'd293:demo_char=8'd69;
  10'd294:demo_char=8'd83;
  10'd295:demo_char=8'd84;
  10'd297:demo_char=8'd76;
  10'd298:demo_char=8'd47;
  10'd299:demo_char=8'd82;
  10'd312:demo_char=8'd76;
  10'd314:demo_char=8'd47;
  10'd316:demo_char=8'd76;
  10'd318:demo_char=8'd68;
  10'd319:demo_char=8'd69;
  10'd320:demo_char=8'd76;
  10'd321:demo_char=8'd65;
  10'd322:demo_char=8'd89;
  10'd323:demo_char=8'd56;
  10'd384:demo_char=8'd75;
  10'd385:demo_char=8'd69;
  10'd386:demo_char=8'd89;
  10'd387:demo_char=8'd48;
  10'd389:demo_char=8'd75;
  10'd390:demo_char=8'd69;
  10'd391:demo_char=8'd89;
  10'd392:demo_char=8'd49;
  10'd394:demo_char=8'd75;
  10'd395:demo_char=8'd69;
  10'd396:demo_char=8'd89;
  10'd397:demo_char=8'd50;
  10'd399:demo_char=8'd47;
  10'd401:demo_char=8'd80;
  10'd402:demo_char=8'd82;
  10'd403:demo_char=8'd69;
  10'd404:demo_char=8'd83;
  10'd405:demo_char=8'd83;
  10'd407:demo_char=8'd84;
  10'd408:demo_char=8'd79;
  10'd410:demo_char=8'd72;
  10'd411:demo_char=8'd73;
  10'd412:demo_char=8'd71;
  10'd413:demo_char=8'd72;
  10'd414:demo_char=8'd76;
  10'd415:demo_char=8'd73;
  10'd416:demo_char=8'd71;
  10'd417:demo_char=8'd72;
  10'd418:demo_char=8'd84;
  10'd512:demo_char=8'd75;
  10'd513:demo_char=8'd69;
  10'd514:demo_char=8'd89;
  10'd515:demo_char=8'd48;
  10'd517:demo_char=8'd61;
  10'd519:demo_char=8'd67;
  10'd520:demo_char=8'd52;
  10'd522:demo_char=8'd47;
  10'd524:demo_char=8'd75;
  10'd525:demo_char=8'd69;
  10'd526:demo_char=8'd89;
  10'd527:demo_char=8'd49;
  10'd529:demo_char=8'd61;
  10'd531:demo_char=8'd69;
  10'd532:demo_char=8'd52;
  10'd534:demo_char=8'd47;
  10'd536:demo_char=8'd75;
  10'd537:demo_char=8'd69;
  10'd538:demo_char=8'd89;
  10'd539:demo_char=8'd50;
  10'd541:demo_char=8'd61;
  10'd543:demo_char=8'd71;
  10'd544:demo_char=8'd52;
  10'd640:demo_char=8'd71;
  10'd641:demo_char=8'd69;
  10'd642:demo_char=8'd78;
  10'd643:demo_char=8'd69;
  10'd644:demo_char=8'd82;
  10'd645:demo_char=8'd65;
  10'd646:demo_char=8'd84;
  10'd647:demo_char=8'd69;
  10'd648:demo_char=8'd68;
  10'd650:demo_char=8'd68;
  10'd651:demo_char=8'd69;
  10'd652:demo_char=8'd77;
  10'd653:demo_char=8'd79;
  10'd655:demo_char=8'd83;
  10'd656:demo_char=8'd73;
  10'd657:demo_char=8'd71;
  10'd658:demo_char=8'd78;
  10'd659:demo_char=8'd65;
  10'd660:demo_char=8'd76;
  10'd662:demo_char=8'd124;
  10'd664:demo_char=8'd86;
  10'd665:demo_char=8'd73;
  10'd666:demo_char=8'd69;
  10'd667:demo_char=8'd87;
  10'd669:demo_char=8'd88;
  10'd670:demo_char=8'd52;
  10'd672:demo_char=8'd124;
  10'd674:demo_char=8'd68;
  10'd675:demo_char=8'd69;
  10'd676:demo_char=8'd76;
  10'd677:demo_char=8'd65;
  10'd678:demo_char=8'd89;
  10'd680:demo_char=8'd56;
  10'd682:demo_char=8'd83;
  10'd683:demo_char=8'd65;
  10'd684:demo_char=8'd77;
  10'd685:demo_char=8'd80;
  10'd686:demo_char=8'd76;
  10'd687:demo_char=8'd69;
  10'd688:demo_char=8'd83;
  default:demo_char=8'd32;
 endcase end endfunction

 wire in_spectrum=h1>=48 && h1<1200 && v1>=512 && v1<600;
 wire [9:0] spectrum_top=10'd600-{2'd0,spectrum_level};
 wire in_wave=h1>=48 && h1<560 && v1>=176 && v1<432;
 wire in_lr=h1>=624 && h1<880 && v1>=176 && v1<432;
 wire in_delay=h1>=944 && h1<1200 && v1>=176 && v1<432;
 // Move coordinate arithmetic off the synchronous waveform RAM data path.
 // These three row coordinates are exactly the original +/-1-pixel line width.
 wire [9:0] wave_y0=v1-10'd176,wave_yp=v1-10'd175,wave_ym=v1-10'd177;
 wire [9:0] wave_l_pos={2'd0,wave_data[15],~wave_data[14:8]};
 wire [9:0] wave_r_pos={2'd0,wave_data[7],~wave_data[6:0]};
 wire wave_l_hit=(wave_y0==wave_l_pos || wave_yp==wave_l_pos || wave_ym==wave_l_pos);
 wire wave_r_hit=(wave_y0==wave_r_pos || wave_yp==wave_r_pos || wave_ym==wave_r_pos);
 integer i;
 reg black_key;
 always @* begin
   color=24'h101a2d;
   if(h1>=32 && h1<1216 && v1>=496 && v1<624)color=24'h0a1221;
   if(v1<96) color=24'h172740;
   // Panels and pixel-exact grids.
   if((h1>=32 && h1<576 && v1>=112 && v1<456) ||
      (h1>=608 && h1<896 && v1>=112 && v1<456) ||
      (h1>=928 && h1<1216 && v1>=112 && v1<456)) color=24'h0a1221;
   if(in_wave) begin
     if(v1==303 || h1==304)color=24'h35445d;
     else if(v1[5:0]==47 || h1[6:0]==48) color=24'h202e45;
     if(front_valid && wave_r_hit) color=24'hff6e9d;
     if(front_valid && wave_l_hit) color=24'h38d9d0;
   end
   if(in_lr || in_delay) begin
     if(v1==303 || (in_lr && h1==751) || (in_delay && h1==1071))color=24'h35445d;
     else if(v1[5:0]==47 || (in_lr && h1[5:0]==48) || (in_delay && h1[5:0]==48))color=24'h202e45;
     if(front_valid && in_lr && lr_pixel)color=24'h38d9d0;
     if(front_valid && in_delay && delay_pixel)color=24'hffbd69;
   end
   if(in_spectrum)begin
     if(v1==599 || v1==575 || v1==551 || v1==527)color=24'h202e45;
     if(spectrum_ready && spectrum_level!=0 && spectrum_subx1<15 && v1>=spectrum_top)
       color=24'h8fd67a;
   end
   black_key=0;
   for(i=0;i<25;i=i+1) begin
     if(h1>=48+i*48 && h1<92+i*48 && v1>=656 && v1<704) begin
       black_key=(i%12==1 || i%12==3 || i%12==6 || i%12==8 || i%12==10);
       color=black_key?24'h24324b:24'hcbd9ea;
       if(keys[i])color=24'h38d9d0;
       if(v1>=696)color=keys[i]?24'h249c98:24'h6a7f9b;
     end
   end
   text_region=(h1>=48 && h1<1248);
   case(v1[9:4])
     2:text_row=0;4:text_row=1;8:text_row=2;29:text_row=3;
     39:text_row=4;44:text_row=5;31:text_row=6;38:text_row=7;
     default:begin text_row=0;text_region=0;end
   endcase
   ch=label_char(text_row,text_col);
   if(text_row==0 || text_row==5 || text_row==6 || text_row==7)ch=extra_label(text_row,text_col);
   if(text_row==3) begin
     if(text_col==7)ch=8'd48+(voices>=30?3:voices>=20?2:voices>=10?1:0);
     if(text_col==8)ch=8'd48+(voices>=30?voices-30:voices>=20?voices-20:voices>=10?voices-10:voices);
     if(instrument==3 && text_col>=16 && text_col<25)
       case(text_col)
         16:ch="C";17:ch="E";18:ch="L";19:ch="L";20:ch="O";
         default:ch=" ";
       endcase
     if(text_col==40)ch=hex_char(velocity[7:4]);
     if(text_col==41)ch=hex_char(velocity[3:0]);
     if(text_col==51)ch=8'd48+effect;
     if(!mono && text_col>=60 && text_col<66)
       case(text_col)
         60:ch="S";61:ch="T";62:ch="E";63:ch="R";64:ch="E";65:ch="O";
       endcase
   end
   if(TEST_SOURCE) ch=demo_char(text_row,text_col);
 end
endmodule
