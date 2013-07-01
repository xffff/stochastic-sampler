/*
Stochastic Sampler
Michael Murphy 2012
*/

StochasticSampler {
	var s;
	var messagebuffer;
	var markovs;
	var randomoscid;
	var buffers;
	var synthgroup;
	var listenersynth;
	var playrecsynths;
	var current;
	var oscin;
	var looproutine;
	var loopfunction;
	var numinchans;
	var >busin = 0;
	var >busout = 0;
	var <markovorder = 4;
	var <updateseeds = true;
	var <numvoices = 25;
	var <numchans = 2;
	var <maxbuflen = 10;
	var <>minsamplelen = 0.03125; // 1/32
	var <>maxsamplelen = 10;
	var <>probrecplay = 0.3;
	var <>maxamp = 0;
	var <>midiroundval = 1;
	var <>maxwaitlen = 60;
	var <>densitymul = 1.0;
	var <>grainramp = 0.2;
	var <>masterampoffset = 1;

	*new{ |l_busin, l_busout,l_numvoices,l_maxbuflen,l_markovorder,l_updateseeds|
		^super.new.init(l_busin, l_busout,l_numvoices,l_maxbuflen,l_markovorder,l_updateseeds);
	}

	init{ |l_busin, l_busout,l_numvoices,l_maxbuflen,l_markovorder,l_updateseeds|
		s = Server.default;
		s.waitForBoot({
			busin = l_busin;
			numinchans = busin.size.max(1);
			busout = l_busout;
			numchans = busout.size.max(1);
			markovorder = l_markovorder.clip(1,10);
			maxbuflen = l_maxbuflen;
			numvoices = l_numvoices.clip(1,500);
			updateseeds = l_updateseeds;
			markovs = Array.fill(3,{MarkovSetN.new(order:markovorder,updateSeeds:updateseeds)});
			messagebuffer = Array.fill(3,{Array.new(markovorder)});
			buffers = Array.fill(numvoices,{Buffer.alloc(s,maxbuflen*s.sampleRate,numinchans)});
			maxamp = numvoices.reciprocal;
			current = 0!3; // array for current pitch, dur, amp
			playrecsynths = Array.fill(2,{Array.newClear(numvoices)});
			// create group for synths
			synthgroup = Group.new;
			//create random id for osc communication...
			randomoscid = {1e3.rand}.dup(3).round(1);
			("StochasticSampler OSC Trigger ID's: "++randomoscid).postln;

			looproutine = Array.newClear(numvoices);
			loopfunction = Array.newClear(numvoices);

			this.addSynths;
			},
			onFailure:{postln("StochasticSampler: The server couldn't be booted");}
		);
	}

	addSynths {
		fork{
			// required synths
			SynthDef(\listener, { |in = 0, freqprecisionhz = 10, freqthreshamp = 0.93, freqthreshdur = 0.1, fftframes = 4096, onsetthresh = 0.5, ampprecision = 0.1, ampthreshdur = 0.1 |

				var freq, freqchanged, onset, chain, sig, amp, ampchanged;
				sig = In.ar(in,numinchans);

				// freq = Pitch.kr(sig,peakThreshold:freqthreshamp);
				freq = Tartini.kr(sig,threshold:freqthreshamp);
				freqchanged = (freq-DelayN.kr(freq,0.01,0.01))>freqprecisionhz;
				freqchanged = Trig1.kr(freqchanged,freqthreshdur);
				SendTrig.kr(freqchanged,randomoscid[0],freq); // send frequency

				chain = FFT(LocalBuf(fftframes),sig);
				onset = Onsets.kr(chain, onsetthresh, \rcomplex);
				SendTrig.kr(onset,randomoscid[1],Timer.kr(onset)); // send onset trigger + time since last triggered

				amp = Amplitude.kr(sig);
				ampchanged = (amp-DelayN.kr(amp,0.01,0.01))>ampprecision;
				ampchanged = Trig1.kr(ampchanged,ampthreshdur);
				SendTrig.kr(ampchanged,randomoscid[2], amp); // send amplitude

			}).add;

			SynthDef(\recbuf, { |in = 0, dur = 1, bufnum = 0|
				var sig = In.ar(in,numinchans);
				Line.kr(1,0,dur,doneAction:2);
				RecordBuf.ar(sig,bufnum,loop:0,doneAction:2);
			}).add;

			SynthDef(\playbuf, { |out = 0, rate = 0, bufnum = 0, amp = 1, samplelen = 5, pan = 0, rampscale = 0.2|
				var dur = (samplelen / rate) * 0.95;
				//var sound = PlayBuf.ar(1,bufnum,rate,loop:0,doneAction:2);
				var sound = PlayBuf.ar(numinchans,bufnum,rate,loop:0,doneAction:2);
				var snum = 1e-3;
				var scaled = rampscale.clip(snum,1.0).linlin(snum,1.0,snum,(dur*0.5)-snum);
				//sound = sound.sum*numinchans.reciprocal; // outchans will get screwed if I panaz >1ch output
				sound = sound * EnvGen.kr(Env.linen(scaled,dur-(scaled*2),scaled,amp,\sin),doneAction:2);
				sound = PanAz.ar(numchans,sound,pan);
				OffsetOut.ar(out,sound);
				//Out.ar(out,sound);
			}).add;
			s.sync;
			"StochasticSampler Ready".postln;
		};

		// we need to hear the messages from SendTrig coming from the server over OSC
		this.initOSC;
	}

	// get pitch messages from SendTrig
	initOSC {
		oscin = OSCFunc.new({ |in,time|
			// sift ids
			case
			{in[2]==randomoscid[0]} {current[0] = (in.flat.reverse[0]).cpsmidi.round(midiroundval);
				this.readvars(0);} // freq (midi)
			{in[2]==randomoscid[1]} {current[1] = in.flat.reverse[0];
				this.readvars(1);} // dur (seconds)
			{in[2]==randomoscid[2]} {current[2] = in.flat.reverse[0];
				this.readvars(2);}; // amp (lin)
		},'/tr', s.addr);
	}

	// deal with messages
	readvars { |i|
		//if the message isn't as big as the order of the markov chain
		//we can just store it until it is
		if(messagebuffer[i].size<markovorder,{
			messagebuffer[i].addFirst(current[i]);
			},{
				if(messagebuffer[i].size==markovorder,{
					// it thinks newest at index n, oldest at index 0
					// we are adding new elements at 0, so we reverse
					markovs[i].read(messagebuffer[i].reverse,current[i]);
					},{
						postln("StochasticSampler: Error: messagebuffer[" ++ i ++ "] size = " ++
							messagebuffer[i].size ++ " should be: " ++ markovorder);
				});

				messagebuffer[i] = messagebuffer[i].addFirst(current[i]);
				messagebuffer[i].removeAt(markovorder);
			}
		);
	}

	listen {
		if(listenersynth.isPlaying,{listenersynth.free});
		listenersynth = Synth(\listener,[\in,busin],synthgroup,\addToHead);
	}

	play {
		// listen for changes in pitch
		this.listen;

		// do this for every voice
		numvoices.do{ |i|
			this.playlooproutine(i);
		};
	}

	playlooproutine { |i|
		var prev = Array.fill(3,{0!markovorder});  // previous freq,dur,amp arrays
		var next = Array.fill(3,{0!markovorder}); // markov generated freq,dur,amp arrays...
		var counter = 0; // count up to markovorder

		loopfunction[i] = {
			loop{
				var waittime;
				var modcounter = counter%markovorder;

				//postln("prev[0] " ++ prev[0] ++ " prev[1] " ++ prev[1] ++ " prev[2] " ++ prev[2]);
				//postln("next[0] " ++ next[0] ++ " next[1] " ++ next[1] ++ " next[2] " ++ next[2]);

				// record or playback dependant upon probability
				if(1.0.rand<probrecplay,{
					this.samprecord(i,prev,next,modcounter);
					},{
						this.sampplay(i,prev,next,modcounter);
					}
				);
				waittime=(
					((next[1][modcounter]+minsamplelen)*densitymul)
					.clip(prev[1][0],maxwaitlen)
				);
				counter = counter + 1;
				waittime.wait;
			};
		};
		looproutine[i] = loopfunction[i].fork;
	}

	samprecord { |i,prev,next,counter|
		if(counter==0,{
			next[1] = markovs[1].next(prev[1].reverse);
			if(next[1].size==0&&next[1].notNil,{
				next[1]=Array.fill(markovorder,{next[1]})
			});
		});

		if(next[1].isNil,{
			// next[1]=Array.fill(markovorder,{current[1].clip(minsamplelen,maxbuflen-0.1);});
			next[1]=Array.fill(markovorder,{maxbuflen});
			},{
				if((next[1][counter].isNil)||(next[1][counter]==0),{
					//current[1].clip(minsamplelen,maxbuflen-0.1).postln;
					//next[1][counter]=current[1].clip(minsamplelen,maxbuflen-0.1);
					next[1][counter]=maxbuflen;
					},{
						next[1][counter]=next[1][counter].clip(minsamplelen,maxsamplelen.min(maxbuflen-0.1));
					}
				);
			}
		);

		//start recording synth
		playrecsynths[0][i] = Synth.after(listenersynth,\recbuf,[
			\in, busin,
			\dur, next[1][counter],
			\bufnum, buffers[i]
			]
		);

		prev[1].removeAt(prev[1].size-1);
		prev[1] = prev[1].addFirst(next[1][counter]);
	}

	sampplay { |i,prev,next,counter|
		if(counter==0,{
			//get markov values for pitch, and amplitude
			next[0] = markovs[0].next(prev[0].reverse);
			next[2] = markovs[2].next(prev[2].reverse);

			if(next[0].isNil,{next[0]=Array.fill(markovorder,{current[0]});});
			if(next[2].isNil,{next[2]=Array.fill(markovorder,{numvoices.reciprocal});});

			if(next[0].size==0&&next[0].notNil,{
				next[0]=Array.fill(markovorder,{next[0]})
			});
			if(next[2].size==0&&next[2].notNil,{
				next[2]=Array.fill(markovorder,{next[2]})
			});
		});

		//we can't play anything if the duration or
		//pitch parameters are not satisfactory
		if((next[0][counter].notNil&&((next[1][counter].notNil)||(next[1][counter]!=0))),{
			var pan=0;
			var playrate = (next[0][counter]-prev[0][0]).midiratio.clip(0.5,2);

			//if there is only one voice I want it in the centre
			//otherwise splay across the speaker field linearly
			if(numvoices>1,{pan=i.linlin(0,numvoices-1,-1.0,1.0)},{pan=0;});
			if(next[2].isNil,{
				next[2]=numvoices.reciprocal;
				},{
					next[2] = next[2].clip(0.0,maxamp);
				}
			);

			//play the recorded buffer...
			playrecsynths[1][i] = Synth(\playbuf,[
				\out,busout,
				\bufnum,buffers[i],
				\rate,playrate,
				\samplelen,prev[1][0],
				\amp,next[2][counter]*masterampoffset,
				\pan,pan,
				\rampscale,grainramp
				],
				synthgroup,
				\addToTail
			);

			//remember the previous values
			[0,2].do{|k|
				prev[k].removeAt(prev[k].size-1);
				prev[k] = prev[k].addFirst(next[k][counter]);
			};
		})
	}

	pause {
		numvoices.do{|i| looproutine[i].stop;}
	}

	unpause {
		numvoices.do{|i| looproutine[i] = loopfunction[i].fork;}
	}

	free {
		this.pause;
		listenersynth.free;
		numvoices.do{|i|
			1.do{|j| if(playrecsynths[j][i].isPlaying,{playrecsynths[j][i].free;})};
			buffers[i].free;
		};
		synthgroup.free;
	}
}